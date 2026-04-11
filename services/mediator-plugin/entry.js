// Minimal OpenClaw plugin entry point — only mediator tools, no NemoClaw
// slash commands or provider registration. This is the version that gets
// installed into the sandbox as a standalone extension.
import { registerMediatorTools } from "./mediator-tools.js";
export default function register(api) {
  registerMediatorTools(api);
}
