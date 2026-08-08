import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// The tests run inside workerd, against the same wrangler.jsonc a deploy reads — so a binding
// that is wrong in the config is wrong in the tests too, rather than passing against a mock and
// failing in the account it was deployed to.
export default defineConfig({
	plugins: [
		cloudflareTest({
			wrangler: { configPath: "./wrangler.jsonc" },
			miniflare: {
				// The real one is a Secret set on the deployed Worker. Here it is whatever the
				// tests agree on — what is under test is the gate, not the value.
				bindings: { AUTH_TOKEN: "a-long-random-token" },
			},
		}),
	],
});
