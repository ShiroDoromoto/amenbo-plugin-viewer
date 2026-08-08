# The Worker's build is npm's; this only gives the root Makefile the three verbs it calls, so
# `make build` at the top of the repository reaches every part the same way.
#
# Nothing here deploys. The Worker goes into the USER's Cloudflare account, and the plugin is
# what puts it there — a deploy target reachable from the top of the repository would be an
# invitation to push it into ours by accident. `npm run deploy` is still there to do it by hand.

NPM := npm

.PHONY: build test clean install

# `npm ci` is the install that honours the lockfile, so what CI builds is what the lockfile pins
# rather than whatever resolved today. The stamp is node_modules itself: `ci` empties and
# rewrites it, so it is newer than the lockfile exactly when it is current.
node_modules: package-lock.json
	$(NPM) ci
	@touch node_modules

install: node_modules

# `wrangler types` first, because the bindings are typed from wrangler.jsonc: one added to the
# config and not regenerated is a type error here rather than an undefined in someone's account.
build: node_modules
	$(NPM) run check

test: node_modules
	$(NPM) test

clean:
	rm -rf node_modules dist .wrangler worker-configuration.d.ts
