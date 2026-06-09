// @ts-check
import { defineConfig } from "astro/config";
import react from "@astrojs/react";

// A single static page with one React island (the scrubber). No SSR, no backend.
export default defineConfig({
  integrations: [react()],
});
