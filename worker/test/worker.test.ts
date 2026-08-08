import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import worker, { type Env } from "../src/index";

const TOKEN = "a-long-random-token";
const AT = "https://viewer.example.workers.dev";

/** A request carrying the token the tests configured. */
function signed(path: string, init: RequestInit = {}): Promise<Response> {
	return SELF.fetch(`${AT}${path}`, {
		...init,
		headers: { Authorization: `Bearer ${TOKEN}`, ...(init.headers ?? {}) },
	});
}

describe("the gate", () => {
	// The gate stands in front of the routing, so an unauthorised caller cannot learn which
	// paths exist by watching 404 turn into 401.
	it("answers the same for a path that exists and one that does not", async () => {
		const real = await SELF.fetch(`${AT}/snapshot`);
		const invented = await SELF.fetch(`${AT}/there-is-no-such-thing`);

		expect(real.status).toBe(401);
		expect(invented.status).toBe(401);
	});

	it("names the scheme it wants, so a caller can fix its request", async () => {
		const response = await SELF.fetch(`${AT}/meta`);

		expect(response.status).toBe(401);
		expect(response.headers.get("WWW-Authenticate")).toBe("Bearer");
	});

	it("refuses a token that is merely close", async () => {
		const response = await SELF.fetch(`${AT}/meta`, {
			headers: { Authorization: `Bearer ${TOKEN.slice(0, -1)}x` },
		});

		expect(response.status).toBe(401);
	});

	it("refuses a token of the wrong length without falling over", async () => {
		const response = await SELF.fetch(`${AT}/meta`, { headers: { Authorization: "Bearer short" } });

		expect(response.status).toBe(401);
	});

	it("refuses another scheme carrying the right value", async () => {
		const response = await SELF.fetch(`${AT}/meta`, { headers: { Authorization: `Basic ${TOKEN}` } });

		expect(response.status).toBe(401);
	});

	it("lets the right token through to the endpoint behind it", async () => {
		const response = await signed("/meta");

		expect(response.status).not.toBe(401);
	});
});

describe("the routes", () => {
	// The three endpoints and nothing else. A fourth would be surface this Worker has no reason
	// to expose, in an account that is not ours.
	it.each([
		["PUT", "/snapshot"],
		["GET", "/snapshot"],
		["GET", "/meta"],
	])("%s %s is dispatched", async (method, path) => {
		const response = await signed(path, { method, body: method === "PUT" ? "…" : undefined });

		expect(response.status).toBe(501);
		expect(await response.json()).toMatchObject({ error: expect.stringContaining("spec/") });
	});

	it("has nothing else", async () => {
		const response = await signed("/tasks");

		expect(response.status).toBe(404);
	});

	// A method the endpoint does not take is not a missing endpoint, and the difference is what
	// tells a caller with a typo from one pointed at the wrong Worker entirely.
	it.each([
		["DELETE", "/snapshot", "PUT, GET, HEAD"],
		["PUT", "/meta", "GET, HEAD"],
		["POST", "/meta", "GET, HEAD"],
	])("%s %s is refused as a method, and says which are allowed", async (method, path, allow) => {
		const response = await signed(path, { method, body: method === "PUT" || method === "POST" ? "…" : undefined });

		expect(response.status).toBe(405);
		expect(response.headers.get("Allow")).toBe(allow);
	});

	// Nothing is written back, ever. The phone reads; the PC writes; there is no third direction.
	it("takes no write anywhere but the snapshot", async () => {
		const response = await signed("/meta", { method: "PUT", body: "…" });

		expect(response.status).toBe(405);
	});
});

describe("a Worker whose Secret was never set", () => {
	// Nobody gets in either way, so nothing leaks — but a deployment missing its Secret is a
	// mistake the owner can fix, and a flat 401 would send them hunting for the wrong thing.
	it("says so, rather than reading as a wrong token", async () => {
		const unconfigured = { ...env, AUTH_TOKEN: "" } as Env;

		const response = await worker.fetch(new Request(`${AT}/meta`), unconfigured);

		expect(response.status).toBe(503);
		expect(await response.json()).toMatchObject({ error: expect.stringContaining("AUTH_TOKEN") });
	});
});

describe("the unbuilt handlers", () => {
	// 501 and not 200-with-a-note: a caller reading only the status has to be able to tell this
	// from a snapshot that actually landed.
	it("refuse rather than pretend", async () => {
		const response = await signed("/snapshot", { method: "PUT", body: "ciphertext" });

		expect(response.status).toBe(501);
	});
});
