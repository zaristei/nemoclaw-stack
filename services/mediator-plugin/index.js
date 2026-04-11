// @nemoclaw/mediator-tools — OpenClaw plugin that registers mediator syscalls
// as native agent tools. Connects directly to the mediator UDS socket using
// the length-prefixed JSON frame protocol — no shell, no child_process.

import { readFileSync } from "node:fs";
import { createConnection } from "node:net";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const SOCKET_PATH = "/sandbox/.mediator/mediator.sock";
const TOKEN_FILE = "/sandbox/.mediator/mediator.sock.token";

let cachedToken = "";

/** Read the mediator token (cached after first read). */
function getToken() {
  if (cachedToken) return cachedToken;
  try {
    cachedToken =
      process.env.MEDIATOR_TOKEN || readFileSync(TOKEN_FILE, "utf-8").trim();
  } catch {
    cachedToken = process.env.MEDIATOR_TOKEN || "";
  }
  return cachedToken;
}

/** Send a request to the mediator daemon over UDS and return the response. */
function callMediator(method, params) {
  return new Promise((resolve) => {
    const socket = process.env.MEDIATOR_SOCKET || SOCKET_PATH;
    const token = getToken();

    const request = {
      id: `plugin-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      method,
      workflow_token: token,
      params: params ?? {},
    };

    const payload = Buffer.from(JSON.stringify(request), "utf-8");
    const frame = Buffer.alloc(4 + payload.length);
    frame.writeUInt32BE(payload.length, 0);
    payload.copy(frame, 4);

    const conn = createConnection(socket);
    const chunks = [];
    let headerParsed = false;
    let expectedLen = 0;

    conn.on("connect", () => conn.write(frame));

    conn.on("data", (data) => {
      chunks.push(data);
      const buf = Buffer.concat(chunks);

      if (!headerParsed && buf.length >= 4) {
        expectedLen = buf.readUInt32BE(0);
        headerParsed = true;
      }

      if (headerParsed && buf.length >= 4 + expectedLen) {
        const respJson = buf.subarray(4, 4 + expectedLen).toString("utf-8");
        conn.destroy();
        try {
          const resp = JSON.parse(respJson);
          if (resp.ok) {
            resolve({ ok: true, result: resp.result });
          } else {
            const err = resp.error || {};
            resolve({
              ok: false,
              error: `[${err.code || "?"}] ${err.message || "unknown error"}`,
            });
          }
        } catch (e) {
          resolve({ ok: false, error: `bad response JSON: ${e.message}` });
        }
      }
    });

    conn.on("error", (err) => {
      resolve({
        ok: false,
        error: `cannot connect to mediator at ${socket}: ${err.message}`,
      });
    });

    // 5-minute timeout for approval-bridge polling.
    conn.setTimeout(310_000, () => {
      conn.destroy();
      resolve({ ok: false, error: "mediator request timed out (5min)" });
    });
  });
}

/** Format a mediator result as an agent tool response. */
function mediatorResult(outcome) {
  return {
    content: [{ type: "text", text: JSON.stringify(outcome, null, 2) }],
  };
}

// ── Tool definitions ────────────────────────────────────────────────────

const TOOLS = [
  {
    name: "policy_propose",
    description:
      "Propose a new child policy for operator approval. This is how you acquire " +
      "capabilities you don't have (web access, file mounts, etc.). The proposal " +
      "is sent to the operator via the approval bridge and blocks until approved " +
      "or denied (5-min timeout). Returns {approved: true/false, reason: '...'}.\n\n" +
      "TRIFECTA RULE: never request a single policy that has all three of " +
      "(1) sensitive data mounts, (2) untrusted input, (3) external network egress. " +
      "Split into reader + processor + sender chains instead.",
    parameters: {
      type: "object",
      properties: {
        config: {
          type: "object",
          description: "Full MediationPolicy object. All fields are required.",
          properties: {
            policy_name: {
              type: "string",
              description: "Unique name (e.g. 'nutrition_fetcher_v1')",
            },
            rationale: {
              type: "string",
              description: "Why this policy is needed — shown to the operator",
            },
            http_allowlist: {
              type: "array",
              items: { type: "string" },
              description:
                "URL patterns the child can reach (e.g. ['https://api.search.brave.com/*'])",
            },
            external_mounts: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  path: { type: "string" },
                  mode: { type: "string" },
                },
              },
            },
            allowed_child_policies: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  policy_name: { type: "string" },
                  inherit: { type: "boolean" },
                },
              },
            },
            bind_ports: {
              description: "Port range [low, high] or null",
            },
            allowed_ipc_targets: {
              type: "array",
              items: { type: "string" },
              description: "Workflow IDs to talk to (use ['init'] to reply to parent)",
            },
            allowed_signal_targets: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  policy_name: { type: "string" },
                  signals: { type: "array", items: { type: "string" } },
                },
              },
            },
          },
          required: [
            "policy_name",
            "rationale",
            "http_allowlist",
            "external_mounts",
            "allowed_child_policies",
            "allowed_ipc_targets",
            "allowed_signal_targets",
          ],
        },
      },
      required: ["config"],
    },
    execute: async (_id, params) =>
      mediatorResult(await callMediator("policy_propose", params)),
  },

  {
    name: "fork_with_policy",
    description:
      "Fork a child workflow under an approved policy. Returns the child's " +
      "workflow_id, workflow_token, and UID.",
    parameters: {
      type: "object",
      properties: {
        workflow_id: { type: "string", description: "Unique ID for the child" },
        policy_name: { type: "string", description: "Approved policy name" },
        inherit: {
          type: "boolean",
          description: "Inherit parent capabilities (usually false)",
        },
      },
      required: ["workflow_id", "policy_name", "inherit"],
    },
    execute: async (_id, params) =>
      mediatorResult(await callMediator("fork_with_policy", params)),
  },

  {
    name: "ipc_send",
    description:
      "Send a one-shot message to another workflow. Use this to request " +
      "data from a child or return results to your parent.",
    parameters: {
      type: "object",
      properties: {
        target_workflow_id: { type: "string" },
        message: { description: "Arbitrary JSON payload" },
      },
      required: ["target_workflow_id", "message"],
    },
    execute: async (_id, params) =>
      mediatorResult(await callMediator("ipc_send", params)),
  },

  {
    name: "mediator_ps",
    description: "List all workflows visible to you.",
    parameters: { type: "object", properties: {} },
    execute: async () => mediatorResult(await callMediator("ps")),
  },

  {
    name: "policy_list",
    description: "List all approved policies you can fork.",
    parameters: { type: "object", properties: {} },
    execute: async () => mediatorResult(await callMediator("policy_list")),
  },

  {
    name: "policy_get",
    description: "Get the full details of an approved policy.",
    parameters: {
      type: "object",
      properties: {
        policy_name: { type: "string" },
      },
      required: ["policy_name"],
    },
    execute: async (_id, params) =>
      mediatorResult(await callMediator("policy_get", params)),
  },

  {
    name: "signal_workflow",
    description: "Send a signal (term/kill/stop/cont) to a workflow.",
    parameters: {
      type: "object",
      properties: {
        target_workflow_id: { type: "string" },
        signal: { type: "string", enum: ["term", "kill", "stop", "cont"] },
      },
      required: ["target_workflow_id", "signal"],
    },
    execute: async (_id, params) =>
      mediatorResult(await callMediator("signal", params)),
  },

  {
    name: "request_port",
    description: "Allocate a port from your policy's bind range.",
    parameters: { type: "object", properties: {} },
    execute: async () => mediatorResult(await callMediator("request_port")),
  },

  {
    name: "revoke_policy",
    description: "Revoke a policy. hard=true also kills running workflows.",
    parameters: {
      type: "object",
      properties: {
        policy_name: { type: "string" },
        hard: { type: "boolean" },
      },
      required: ["policy_name", "hard"],
    },
    execute: async (_id, params) =>
      mediatorResult(await callMediator("revoke_policy", params)),
  },
];

// ── Plugin entry ────────────────────────────────────────────────────────

export default definePluginEntry({
  id: "mediator-tools",
  name: "Mediator Syscall Tools",
  description:
    "Exposes mediator syscalls as native agent tools via direct UDS connection.",
  register(api) {
    for (const tool of TOOLS) {
      api.registerTool(tool);
    }
    api.logger.info(`Registered ${TOOLS.length} mediator tools`);
  },
});
