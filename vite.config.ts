import type { Connect } from "vite";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

import { handleSessionDevRequest, writeJsonResponse } from "./src/dev/session-dev-bridge.js";

function sessionBridgeMiddleware(): Connect.NextHandleFunction {
  return async (request, response, next) => {
    if (!request.url?.startsWith("/api/")) {
      next();
      return;
    }

    await writeJsonResponse(response, () => handleSessionDevRequest(request, process.cwd()));
  };
}

export default defineConfig({
  plugins: [
    react(),
    {
      name: "latest-session-api",
      configureServer(server) {
        server.middlewares.use(sessionBridgeMiddleware());
      },
      configurePreviewServer(server) {
        server.middlewares.use(sessionBridgeMiddleware());
      },
    },
  ],
});
