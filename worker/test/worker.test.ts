import { SELF, env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import worker, { type Env } from "../src/index";

const WRITE_TOKEN = "a-long-random-write-token";
const AT = "https://viewer.example.workers.dev";

/** A request carrying whichever token the test wants it to. */
function carrying(token: string, path: string, init: RequestInit = {}): Promise<Response> {
	return SELF.fetch(`${AT}${path}`, {
		...init,
		headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) },
	});
}

/** A request carrying the token the PC writes with. */
function signed(path: string, init: RequestInit = {}): Promise<Response> {
	return carrying(WRITE_TOKEN, path, init);
}

/** The hash a PC sends when it pairs a phone: SHA-256, lower-case hex. */
async function hashOf(token: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
	return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Pairs a phone the way the PC does, and hands back the token that phone now reads with. */
async function pair(label: string, token: string): Promise<Response> {
	return signed("/tokens", {
		method: "PUT",
		body: JSON.stringify({ label, hash: await hashOf(token) }),
	});
}

beforeEach(async () => {
	await env.RECORDS.exec("DELETE FROM tokens");
});

describe("the gate", () => {
	// The gate stands in front of the routing, so a caller carrying nothing we know cannot learn
	// which paths exist by watching 404 turn into 401.
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

	it.each([
		["merely close", `${WRITE_TOKEN.slice(0, -1)}x`],
		["the wrong length", "short"],
		["empty", ""],
	])("refuses a token that is %s", async (_what, token) => {
		const response = await SELF.fetch(`${AT}/meta`, { headers: { Authorization: `Bearer ${token}` } });

		expect(response.status).toBe(401);
	});

	it("refuses another scheme carrying the right value", async () => {
		const response = await SELF.fetch(`${AT}/meta`, { headers: { Authorization: `Basic ${WRITE_TOKEN}` } });

		expect(response.status).toBe(401);
	});

	it("lets the write token through to the endpoint behind it", async () => {
		const response = await signed("/snapshot", { method: "PUT", body: "…" });

		expect(response.status).not.toBe(401);
	});
});

describe("the two kinds of token", () => {
	// The whole point of two kinds: what a phone holds cannot write, so a token photographed off
	// somebody's screen cannot put anything into the store.
	it("refuse a read token at a door that writes", async () => {
		await pair("iPhone", "the-phone's-own-token");

		const response = await carrying("the-phone's-own-token", "/snapshot", { method: "PUT", body: "…" });

		expect(response.status).toBe(403);
		expect(await response.json()).toMatchObject({ error: expect.stringContaining("write") });
	});

	// And the other way. The PC has no business reading what it just wrote, and a write token
	// that could read would be one credential doing both jobs again.
	it("refuse the write token at a door that reads", async () => {
		const response = await signed("/meta");

		expect(response.status).toBe(403);
	});

	it("let a read token read", async () => {
		await pair("iPhone", "the-phone's-own-token");

		const response = await carrying("the-phone's-own-token", "/meta");

		expect(response.status).toBe(501);
	});

	// A refusal for the wrong kind is only reached once the caller is known, so it never tells an
	// outsider which endpoints exist.
	it("say nothing about the endpoint to a caller with no token at all", async () => {
		const response = await SELF.fetch(`${AT}/tokens`, { method: "PUT", body: "{}" });

		expect(response.status).toBe(401);
	});
});

describe("the routes", () => {
	it.each([
		["PUT", "/snapshot", WRITE_TOKEN],
		["GET", "/snapshot", "the-phone's-own-token"],
		["GET", "/meta", "the-phone's-own-token"],
	])("%s %s is dispatched", async (method, path, token) => {
		await pair("iPhone", "the-phone's-own-token");

		const response = await carrying(token, path, { method, body: method === "PUT" ? "…" : undefined });

		expect(response.status).toBe(501);
		expect(await response.json()).toMatchObject({ error: expect.stringContaining("not built yet") });
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
		["POST", "/tokens", "PUT"],
		["GET", "/tokens/iPhone", "DELETE"],
	])("%s %s is refused as a method, and says which are allowed", async (method, path, allow) => {
		const response = await signed(path, { method, body: method === "PUT" || method === "POST" ? "…" : undefined });

		expect(response.status).toBe(405);
		expect(response.headers.get("Allow")).toBe(allow);
	});
});

describe("a Worker whose Secret was never set", () => {
	// Nobody gets in either way, so nothing leaks — but a deployment missing its Secret is a
	// mistake the owner can fix, and a flat 401 would send them hunting for the wrong thing.
	it("says so, rather than reading as a wrong token", async () => {
		const unconfigured = { ...env, WRITE_TOKEN: "" } as Env;

		const response = await worker.fetch(new Request(`${AT}/meta`), unconfigured);

		expect(response.status).toBe(503);
		expect(await response.json()).toMatchObject({ error: expect.stringContaining("WRITE_TOKEN") });
	});
});

describe("pairing a phone", () => {
	it("takes a label and a hash, and says when it was issued", async () => {
		const response = await pair("iPhone", "the-phone's-own-token");

		expect(response.status).toBe(200);
		expect(await response.json()).toMatchObject({ label: "iPhone", issued_at: expect.stringContaining("T") });
	});

	// The token itself never arrives — the PC shows it on a QR and sends only its hash, so the
	// value exists on the PC and on the phone that photographed it, and nowhere else.
	it("never receives the token itself", async () => {
		await pair("iPhone", "the-phone's-own-token");

		const { results } = await env.RECORDS.prepare("SELECT hash FROM tokens").all();

		expect(results[0].hash).not.toBe("the-phone's-own-token");
		expect(results[0].hash).toBe(await hashOf("the-phone's-own-token"));
	});

	// Re-pairing the same phone replaces what it had. Leaving both live would mean a phone that
	// was handed on still reads, and nobody would know to revoke a token they thought was gone.
	it("replaces what a label already had", async () => {
		await pair("iPhone", "the-old-token");

		await pair("iPhone", "the-new-token");

		expect((await carrying("the-old-token", "/meta")).status).toBe(401);
		expect((await carrying("the-new-token", "/meta")).status).toBe(501);
	});

	it.each([
		["nothing at all", "{}"],
		["a blank label", JSON.stringify({ label: "  ", hash: "a".repeat(64) })],
		["a hash that is not one", JSON.stringify({ label: "iPhone", hash: "not-a-hash" })],
		["a hash of the wrong length", JSON.stringify({ label: "iPhone", hash: "abc" })],
		["something that is not a document", "{{{"],
	])("refuses %s", async (_what, body) => {
		const response = await signed("/tokens", { method: "PUT", body });

		expect(response.status).toBe(400);
	});
});

describe("cutting one phone off", () => {
	it("stops that phone and leaves the others reading", async () => {
		await pair("iPhone", "the-lost-phone's-token");
		await pair("Android", "the-other-phone's-token");

		const response = await signed("/tokens/iPhone", { method: "DELETE" });

		expect(response.status).toBe(200);
		expect((await carrying("the-lost-phone's-token", "/meta")).status).toBe(401);
		expect((await carrying("the-other-phone's-token", "/meta")).status).toBe(501);
	});

	// Revoking is what someone does when a phone is lost. A typo that answered "done" would leave
	// them believing they had cut off a phone that is still reading.
	it("says so when there was no such phone", async () => {
		const response = await signed("/tokens/NeverPaired", { method: "DELETE" });

		expect(response.status).toBe(404);
	});

	// A label is the user's own words, so it can hold a space or a character a URL has to escape.
	it("takes a label that had to be escaped to fit in a path", async () => {
		await pair("Ai's iPhone", "the-phone's-own-token");

		const response = await signed(`/tokens/${encodeURIComponent("Ai's iPhone")}`, { method: "DELETE" });

		expect(response.status).toBe(200);
		expect((await carrying("the-phone's-own-token", "/meta")).status).toBe(401);
	});
});
