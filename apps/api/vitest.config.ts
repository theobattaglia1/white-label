import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    // Each file gets its own isolate so store state doesn't bleed between
    // test files if we add more later.
    isolate: true,
  },
});
