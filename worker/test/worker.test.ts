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

/** A body the way the PC sends one. */
function placement(version: number, records: unknown[]): string {
	return JSON.stringify({ spec_v: 1, version, records });
}

/** One part of a turn the PC is sending in more than one request. */
function sendingPart(
	path: "/records" | "/reset",
	version: number,
	part: number,
	parts: number,
	records: unknown[],
): Promise<Response> {
	return signed(path, { method: "PUT", body: JSON.stringify({ spec_v: 1, version, part, parts, records }) });
}

/** One record sealed on the PC, as it travels. */
function sealed(k: string): Record<string, string> {
	return { k, op: "put", n: `nonce-for-${k}`, c: `ciphertext-for-${k}` };
}

/** Sends a body the way the PC does, to either of the two doors that take one. */
function sending(path: "/records" | "/reset", version: number, records: unknown[]): Promise<Response> {
	return signed(path, { method: "PUT", body: placement(version, records) });
}

/**
 * Reads the way a phone does. The pairing is done here rather than in each test because every read
 * needs one and none of them are about it — and only when that phone is not paired already, since
 * issuing under a label that is there is refused.
 */
async function reading(path: string): Promise<Response> {
	const paired = await env.RECORDS.prepare("SELECT 1 FROM tokens WHERE label = ?").bind("iPhone").first();
	if (!paired) {
		await pair("iPhone", "the-phone's-own-token");
	}
	return carrying("the-phone's-own-token", path);
}

beforeEach(async () => {
	await env.RECORDS.exec("DELETE FROM tokens");
	await env.RECORDS.exec("DELETE FROM records");
	await env.RECORDS.exec("UPDATE store SET version = NULL, updated_at = NULL, seq = 0, replacing = 0, placed_from = 0 WHERE id = 1");
});

describe("the gate", () => {
	// The gate stands in front of the routing, so a caller carrying nothing we know cannot learn
	// which paths exist by watching 404 turn into 401.
	it("answers the same for a path that exists and one that does not", async () => {
		const real = await SELF.fetch(`${AT}/records`);
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
		const response = await signed("/records", { method: "PUT", body: placement(1, []) });

		expect(response.status).toBe(200);
	});
});

describe("the two kinds of token", () => {
	// The whole point of two kinds: what a phone holds cannot write, so a token photographed off
	// somebody's screen cannot put anything into the store.
	it("refuse a read token at a door that writes", async () => {
		await pair("iPhone", "the-phone's-own-token");

		const response = await carrying("the-phone's-own-token", "/records", { method: "PUT", body: placement(1, []) });

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

		expect(response.status).toBe(200);
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
		["PUT", "/records", WRITE_TOKEN],
		["PUT", "/reset", WRITE_TOKEN],
		["GET", "/records", "the-phone's-own-token"],
		["GET", "/meta", "the-phone's-own-token"],
	])("%s %s is dispatched", async (method, path, token) => {
		await pair("iPhone", "the-phone's-own-token");

		const response = await carrying(token, path, { method, body: method === "PUT" ? placement(1, []) : undefined });

		expect(response.status).toBe(200);
	});

	it("has nothing else", async () => {
		const response = await signed("/tasks");

		expect(response.status).toBe(404);
	});

	// A method the endpoint does not take is not a missing endpoint, and the difference is what
	// tells a caller with a typo from one pointed at the wrong Worker entirely.
	it.each([
		["DELETE", "/records", "PUT, GET, HEAD"],
		["GET", "/reset", "PUT"],
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

	// Issuing over a name that is there would cut off whatever phone holds it, silently — a
	// mistyped name is all that takes. So the name has to be freed first, and the phone that has
	// it goes on reading until someone says otherwise.
	it("refuses a label that is already there, and leaves that phone reading", async () => {
		await pair("iPhone", "the-old-token");

		const response = await pair("iPhone", "the-new-token");

		expect(response.status).toBe(409);
		expect((await carrying("the-old-token", "/meta")).status).toBe(200);
		expect((await carrying("the-new-token", "/meta")).status).toBe(401);
	});

	// Cutting one off is what frees its name, which is what makes re-pairing the same phone two
	// moves rather than an impossibility.
	it("takes the label again once that phone has been cut off", async () => {
		await pair("iPhone", "the-old-token");
		await signed("/tokens/iPhone", { method: "DELETE" });

		const response = await pair("iPhone", "the-new-token");

		expect(response.status).toBe(200);
		expect((await carrying("the-new-token", "/meta")).status).toBe(200);
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
		expect((await carrying("the-other-phone's-token", "/meta")).status).toBe(200);
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

describe("placing what moved", () => {
	it("takes the records and answers with where the order now stands", async () => {
		const response = await sending("/records", 12345, [sealed("task/1"), sealed("task/2")]);

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ seq: 2 });
	});

	// A record that moves again is the same record, so it keeps its one row and takes a later
	// place in the order — two rows for one key would show a phone the record twice, once stale.
	it("moves a record that comes again to the front of the order", async () => {
		await sending("/records", 1, [sealed("task/1"), sealed("task/2")]);

		await sending("/records", 2, [sealed("task/1")]);

		const { results } = await env.RECORDS.prepare("SELECT k, seq FROM records ORDER BY seq").all();
		expect(results).toEqual([
			{ k: "task/2", seq: 2 },
			{ k: "task/1", seq: 3 },
		]);
	});

	// A deletion is a row of its own with nothing in the envelope, so a phone that was away learns
	// the record went rather than never hearing of it again.
	it("takes a deletion as a record with an empty envelope", async () => {
		await sending("/records", 1, [sealed("task/1")]);

		await sending("/records", 2, [{ k: "task/1", op: "del" }]);

		const { results } = await env.RECORDS.prepare("SELECT op, nonce, ciphertext FROM records").all();
		expect(results).toEqual([{ op: "del", nonce: null, ciphertext: null }]);
	});

	// A sender that did not hear the answer sends again, and the same version means the same
	// records. Placing them a second time would move every one of them to the front of the order,
	// and every phone would fetch the whole store back for nothing.
	it("lets a repeat of the version it already holds through untouched", async () => {
		await sending("/records", 12345, [sealed("task/1")]);

		const response = await sending("/records", 12345, [sealed("task/2")]);

		expect(await response.json()).toEqual({ seq: 1 });
		const { results } = await env.RECORDS.prepare("SELECT k FROM records").all();
		expect(results).toEqual([{ k: "task/1" }]);
	});

	// The version travels so a phone can tell what it is looking at, and it only means anything if
	// it moved with the records it came in with.
	it("remembers the version and when the records landed", async () => {
		await sending("/records", 12345, [sealed("task/1")]);

		const { version, updated_at } = (await reading("/meta").then((it) => it.json())) as {
			version: number;
			updated_at: string;
		};

		expect(version).toBe(12345);
		expect(Date.parse(updated_at)).not.toBeNaN();
	});

	// Too much is refused at the door with a sentence saying what to do about it, rather than
	// failing somewhere inside the database where the sender learns only that it did not work.
	it("refuses more records than one write takes, and says to send it in parts", async () => {
		const records = Array.from({ length: 501 }, (_at, n) => sealed(`task/${n}`));

		const response = await sending("/records", 1, records);

		expect(response.status).toBe(413);
		expect(await response.json()).toMatchObject({ error: expect.stringContaining("in parts") });
	});

	it.each([
		["a contract version it does not read", JSON.stringify({ spec_v: 2, version: 1, records: [] })],
		["nothing at all", "{}"],
		["no version", JSON.stringify({ spec_v: 1, records: [] })],
		["a version that is not a number", JSON.stringify({ spec_v: 1, version: "12345", records: [] })],
		["records that are not a list", JSON.stringify({ spec_v: 1, version: 1, records: {} })],
		["a record with no key", JSON.stringify({ spec_v: 1, version: 1, records: [{ op: "put", n: "n", c: "c" }] })],
		["an operation it has no reading for", JSON.stringify({ spec_v: 1, version: 1, records: [{ k: "task/1", op: "archive" }] })],
		["a put with no envelope", JSON.stringify({ spec_v: 1, version: 1, records: [{ k: "task/1", op: "put" }] })],
		["something that is not a document", "{{{"],
	])("refuses %s", async (_what, body) => {
		const response = await signed("/records", { method: "PUT", body });

		expect(response.status).toBe(400);
	});
});

describe("reading what moved", () => {
	it("hands back everything after a point in the order", async () => {
		await sending("/records", 1, [sealed("task/1"), sealed("task/2"), sealed("task/3")]);

		const answered = (await reading("/records?since=1").then((it) => it.json())) as {
			records: Record<string, string>[];
		};

		expect(answered.records).toEqual([sealed("task/2"), sealed("task/3")]);
	});

	it("reads from the beginning when asked for no point at all", async () => {
		await sending("/records", 1, [sealed("task/1")]);

		const answered = (await reading("/records").then((it) => it.json())) as { records: unknown[] };

		expect(answered.records).toEqual([sealed("task/1")]);
	});

	// The phone remembers where the page got to and asks from there, so what it costs to be a week
	// behind is a few more pages rather than the whole store in one answer.
	it("splits a long stretch into pages, and says there is more", async () => {
		await sending("/reset", 1, Array.from({ length: 250 }, (_at, n) => sealed(`task/${n}`)));

		const first = (await reading("/records?since=0").then((it) => it.json())) as {
			seq: number;
			more: boolean;
			records: unknown[];
		};
		const next = (await reading(`/records?since=${first.seq}`).then((it) => it.json())) as {
			seq: number;
			more: boolean;
			records: unknown[];
		};

		expect(first).toMatchObject({ seq: 200, more: true });
		expect(first.records).toHaveLength(200);
		expect(next).toMatchObject({ seq: 250, more: false });
		expect(next.records).toHaveLength(50);
	});

	it("says where it is and what it is reading, alongside the records", async () => {
		await sending("/records", 12345, [sealed("task/1")]);

		const answered = await reading("/records?since=0").then((it) => it.json());

		expect(answered).toMatchObject({ spec_v: 1, version: 12345, seq: 1, more: false });
	});

	it("stays where it is when there is nothing after the point asked for", async () => {
		await sending("/records", 1, [sealed("task/1")]);

		const answered = await reading("/records?since=1").then((it) => it.json());

		expect(answered).toMatchObject({ seq: 1, more: false, records: [] });
	});

	// A deletion has nothing to open, and a phone that was handed an empty envelope would try.
	it("hands a deletion back with no envelope on it", async () => {
		await sending("/records", 1, [{ k: "task/1", op: "del" }]);

		const answered = (await reading("/records?since=0").then((it) => it.json())) as { records: unknown[] };

		expect(answered.records).toEqual([{ k: "task/1", op: "del" }]);
	});

	// The order never rewinds, so a cursor past the end is not a phone that is early — it is one
	// paired with a store that no longer exists, and answering the tail would hand it somebody
	// else's rows under numbers it recognises.
	it("refuses a cursor that is past the end of the order", async () => {
		await sending("/records", 1, [sealed("task/1")]);

		const response = await reading("/records?since=99");

		expect(response.status).toBe(409);
		expect(await response.json()).toMatchObject({ error: expect.stringContaining("from the beginning") });
	});

	it.each([
		["not a number", "?since=soon"],
		["a number with a sign on it", "?since=-1"],
		["empty", "?since="],
	])("refuses a point in the order that is %s", async (_what, query) => {
		const response = await reading(`/records${query}`);

		expect(response.status).toBe(400);
	});
});

describe("where the store stands", () => {
	// The cheap question, asked before the expensive one: a phone that is level learns so for the
	// price of one small answer, which is what lets it ask often.
	it("says nothing has landed yet, rather than nothing at all", async () => {
		const answered = await reading("/meta").then((it) => it.json());

		expect(answered).toEqual({ spec_v: 1, version: null, seq: 0, updated_at: null, placed_from: 0 });
	});

	it("says the version and how far the order has got", async () => {
		await sending("/records", 12345, [sealed("task/1"), sealed("task/2")]);

		const answered = await reading("/meta").then((it) => it.json());

		expect(answered).toMatchObject({ spec_v: 1, version: 12345, seq: 2 });
	});
});

describe("placing the whole store again", () => {
	it("empties what was there and takes the whole of it", async () => {
		await sending("/records", 1, [sealed("task/1"), sealed("task/2")]);

		await sending("/reset", 2, [sealed("task/3")]);

		const { results } = await env.RECORDS.prepare("SELECT k FROM records").all();
		expect(results).toEqual([{ k: "task/3" }]);
	});

	// The rows that held the high point are gone, and if the numbering started again with them
	// then every phone still holding a cursor from before would be handed the wrong half of the
	// store, under numbers it had no reason to doubt.
	it("carries the order on rather than starting it again", async () => {
		await sending("/records", 1, [sealed("task/1"), sealed("task/2")]);

		const response = await sending("/reset", 2, [sealed("task/3")]);

		expect(await response.json()).toEqual({ seq: 3 });
	});

	// A phone that was level before a reset is behind after one, and what it is behind by is the
	// whole store — which is exactly what it has to be handed.
	// A phone that was level before the reset is not read on from: everything it holds was made
	// again under other numbers, and a record deleted before the reset is in neither the placement
	// nor a row saying it went. Sent back to the beginning, it gets the whole placement.
	it("sends a phone that was level back to the beginning, and has it all waiting there", async () => {
		await sending("/records", 1, [sealed("task/1")]);

		await sending("/reset", 2, [sealed("task/1"), sealed("task/2")]);

		expect((await reading("/records?since=1")).status).toBe(409);
		const answered = (await reading("/records?since=0").then((it) => it.json())) as { records: unknown[] };
		expect(answered.records).toEqual([sealed("task/1"), sealed("task/2")]);
	});

	// The failure the whole of this exists for. Without it the phone reads on from 1, is handed
	// only the placement, and keeps `task/1` — which the backlog no longer has — for good.
	it("does not let a phone keep a record that went while it was away", async () => {
		await sending("/records", 1, [sealed("task/1")]);
		// Deleted while the phone is away, then lost with every other row when the reset empties.
		await sending("/records", 2, [{ k: "task/1", op: "del" }]);
		await sending("/reset", 3, [sealed("task/2")]);

		expect((await reading("/records?since=1")).status).toBe(409);
		const answered = (await reading("/records?since=0").then((it) => it.json())) as { records: unknown[] };
		expect(answered.records).toEqual([sealed("task/2")]);
	});

	// A phone reading inside the placement is not sent back: what it holds is the front of this
	// placement rather than of the one before it, so it is behind and not wrong.
	it("lets a phone that is partway through the placement read on", async () => {
		await sending("/records", 1, [sealed("task/1")]);
		await sending("/reset", 2, [sealed("task/2"), sealed("task/3")]);

		const answered = (await reading("/records?since=2").then((it) => it.json())) as { records: unknown[] };
		expect(answered.records).toEqual([sealed("task/3")]);
	});

	it("says where the placement began, so a phone can tell before it asks", async () => {
		await sending("/records", 1, [sealed("task/1")]);

		await sending("/reset", 2, [sealed("task/2")]);

		expect(await reading("/meta").then((it) => it.json())).toMatchObject({ placed_from: 1, seq: 2 });
	});

	// A reset is the repair path — a sender reaches for it when it has lost track of what the
	// store holds, and a version that happens to match is no reason to leave it as it is.
	it("does the work even when the version is the one already held", async () => {
		await sending("/records", 12345, [sealed("task/1")]);

		await sending("/reset", 12345, [sealed("task/2")]);

		const { results } = await env.RECORDS.prepare("SELECT k FROM records").all();
		expect(results).toEqual([{ k: "task/2" }]);
	});
});

describe("sending one turn in more than one request", () => {
	// The later parts carry the same version as the first, and a store that wrote the version down
	// on the first would read every one of them as a repeat and throw them away — leaving a phone
	// the first five hundred records of a backlog and the version saying that is all of it.
	it("takes every part rather than reading the later ones as a repeat", async () => {
		await sendingPart("/records", 12345, 1, 2, [sealed("task/1")]);

		await sendingPart("/records", 12345, 2, 2, [sealed("task/2")]);

		const { results } = await env.RECORDS.prepare("SELECT k FROM records ORDER BY seq").all();
		expect(results).toEqual([{ k: "task/1" }, { k: "task/2" }]);
	});

	// The version is what a phone reads to know what it is looking at, so a turn that has not
	// finished arriving must not be named by it.
	it("writes the version down only once the last part has landed", async () => {
		await sendingPart("/records", 12345, 1, 2, [sealed("task/1")]);
		expect(await reading("/meta").then((it) => it.json())).toMatchObject({ version: null, seq: 1 });

		await sendingPart("/records", 12345, 2, 2, [sealed("task/2")]);

		expect(await reading("/meta").then((it) => it.json())).toMatchObject({ version: 12345, seq: 2 });
	});

	// Only the first part empties. A later one emptying again would leave the store holding
	// whichever part happened to arrive last, and nothing else.
	it("empties on the first part of a replacement and not on the ones after it", async () => {
		await sending("/records", 1, [sealed("task/old")]);

		await sendingPart("/reset", 2, 1, 2, [sealed("task/1")]);
		await sendingPart("/reset", 2, 2, 2, [sealed("task/2")]);

		const { results } = await env.RECORDS.prepare("SELECT k FROM records ORDER BY seq").all();
		expect(results).toEqual([{ k: "task/1" }, { k: "task/2" }]);
	});

	// Emptying first is what makes the middle of a replacement a lie: what is here is a fraction of
	// the backlog, and a phone cannot tell that from a backlog that really did shrink to a fraction.
	it.each([["/records?since=0"], ["/meta"]])("closes %s while a replacement is half placed", async (path) => {
		await sendingPart("/reset", 2, 1, 2, [sealed("task/1")]);

		const response = await reading(path);

		expect(response.status).toBe(503);
		expect(response.headers.get("Retry-After")).toBe("5");
	});

	it("opens the reading doors again once the last part has landed", async () => {
		await sendingPart("/reset", 2, 1, 2, [sealed("task/1")]);

		await sendingPart("/reset", 2, 2, 2, [sealed("task/2")]);

		const answered = (await reading("/records?since=0").then((it) => it.json())) as { records: unknown[] };
		expect(answered.records).toEqual([sealed("task/1"), sealed("task/2")]);
	});

	// A replacement nobody finished has left a partial store behind, and only another whole
	// placement can put that right. Records laid on top of it would make it look whole again.
	it("keeps them closed for a placement that only adds", async () => {
		await sendingPart("/reset", 2, 1, 2, [sealed("task/1")]);

		await sending("/records", 3, [sealed("task/2")]);

		expect(await reading("/meta").then((it) => it.status)).toBe(503);
	});

	// One request is one whole turn, which is what every send was before there were parts at all.
	it("takes a body that says nothing about parts as the whole of a turn", async () => {
		await sending("/reset", 2, [sealed("task/1")]);

		expect(await reading("/meta").then((it) => it.json())).toMatchObject({ version: 2, seq: 1 });
	});

	it.each([
		["a part that is not a number", JSON.stringify({ spec_v: 1, version: 1, part: "1", parts: 2, records: [] })],
		["a part before the first", JSON.stringify({ spec_v: 1, version: 1, part: 0, parts: 2, records: [] })],
		["a part past the last", JSON.stringify({ spec_v: 1, version: 1, part: 3, parts: 2, records: [] })],
		["a turn of no parts at all", JSON.stringify({ spec_v: 1, version: 1, part: 1, parts: 0, records: [] })],
		["a count of parts that is not whole", JSON.stringify({ spec_v: 1, version: 1, part: 1, parts: 1.5, records: [] })],
	])("refuses %s", async (_what, body) => {
		const response = await signed("/records", { method: "PUT", body });

		expect(response.status).toBe(400);
	});
});

describe("a store with no room left", () => {
	/**
	 * What the binding throws when D1 is out of room, copied off a real database filled to its
	 * ceiling: a plain `Error`, no code and no status, and the `7500` the REST API answers with
	 * nowhere in it. The message is the only thing there is to go on.
	 */
	const NO_ROOM = () =>
		new Error("D1_ERROR: Exceeded maximum DB size", { cause: new Error("Exceeded maximum DB size") });

	/** A D1 failure that is not about room, as one arrives. */
	const SOMETHING_ELSE = () =>
		new Error(
			"D1_ERROR: UNIQUE constraint failed: records.seq: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_UNIQUE)",
		);

	/**
	 * The same database, but every write fails the given way. Reads are left alone: the gate has
	 * to let the caller in for any of this to be reached, and a full store still answers them.
	 */
	function whereWritesFail(error: () => Error): Env {
		const statement = (real: D1PreparedStatement): D1PreparedStatement =>
			new Proxy(real, {
				get(target, property, receiver) {
					if (property === "bind") {
						return (...values: unknown[]) => statement(target.bind(...values));
					}
					if (property === "run") {
						return () => Promise.reject(error());
					}
					const value = Reflect.get(target, property, receiver);
					return typeof value === "function" ? value.bind(target) : value;
				},
			});
		const database = new Proxy(env.RECORDS, {
			get(target, property, receiver) {
				if (property === "batch") {
					return () => Promise.reject(error());
				}
				if (property === "prepare") {
					return (sql: string) => statement(target.prepare(sql));
				}
				const value = Reflect.get(target, property, receiver);
				return typeof value === "function" ? value.bind(target) : value;
			},
		});
		return { ...env, RECORDS: database } as Env;
	}

	/** A request the PC's token carries, against a store standing in for a full one. */
	function into(store: Env, path: string, init: RequestInit = {}): Promise<Response> {
		return worker.fetch(
			new Request(`${AT}${path}`, {
				...init,
				headers: { Authorization: `Bearer ${WRITE_TOKEN}`, ...(init.headers ?? {}) },
			}),
			store,
		);
	}

	it("says the store is full, and what makes room", async () => {
		const response = await into(whereWritesFail(NO_ROOM), "/records", {
			method: "PUT",
			body: placement(1, [sealed("task/1")]),
		});

		expect(response.status).toBe(507);
		expect(await response.json()).toMatchObject({ error: expect.stringContaining("no room left") });
	});

	it("says the same when the whole store is being placed again", async () => {
		const response = await into(whereWritesFail(NO_ROOM), "/reset", {
			method: "PUT",
			body: placement(1, [sealed("task/1")]),
		});

		expect(response.status).toBe(507);
	});

	it("says the same when a phone is being paired", async () => {
		const response = await into(whereWritesFail(NO_ROOM), "/tokens", {
			method: "PUT",
			body: JSON.stringify({ label: "iPhone", hash: await hashOf("the-phone's-own-token") }),
		});

		expect(response.status).toBe(507);
	});

	// Room is the one D1 failure anyone can act on. A database that was briefly unreachable, told
	// as "buy more storage", sends someone to pay for something that was never the matter.
	it("leaves every other D1 failure alone", async () => {
		const refused = into(whereWritesFail(SOMETHING_ELSE), "/records", {
			method: "PUT",
			body: placement(1, [sealed("task/1")]),
		});

		await expect(refused).rejects.toThrow("UNIQUE constraint failed");
	});
});

/**
 * The size of a real backlog, as the store that went to iCloud held it.
 *
 * **This is the run that was never made.** Every test above works at two or three records, and
 * what broke on the other route broke only once there were twenty thousand — so the number itself
 * is the point here, not the shape. It is not a round one on purpose: a backlog that divides
 * evenly into writes and pages never sends a short last one, and a real turn always does.
 */
const A_REAL_BACKLOG = 20202;

/**
 * How long a test at that size is given.
 *
 * The default of five seconds is right for a test at three records and wrong for one at twenty
 * thousand: reading this backlog back is a hundred and two pages, and a runner slower than a
 * laptop crosses five seconds on the way. The number is a ceiling on a test that has already
 * passed, not a target — what it buys is the difference between a slow machine and a broken one.
 */
const LONG_ENOUGH_FOR_A_REAL_BACKLOG = 60_000;

describe("the whole of a real backlog", () => {
	/** Places `total` records through the door that empties first, in the parts a write takes. */
	async function placeWhole(total: number, version: number): Promise<void> {
		const parts = Math.ceil(total / 500);
		for (let part = 1; part <= parts; part++) {
			const from = (part - 1) * 500;
			const records = Array.from({ length: Math.min(500, total - from) }, (_, at) => sealed(`task/${from + at}`));
			const answered = await sendingPart("/reset", version, part, parts, records);
			expect(answered.status, `part ${part} of ${parts}`).toBe(200);
		}
	}

	it("holds every record it was sent, once each", async () => {
		await placeWhole(A_REAL_BACKLOG, 7);

		const held = await env.RECORDS.prepare("SELECT COUNT(*) AS n FROM records").first<{ n: number }>();
		expect(held?.n).toBe(A_REAL_BACKLOG);
		const distinct = await env.RECORDS.prepare("SELECT COUNT(DISTINCT k) AS n FROM records").first<{ n: number }>();
		expect(distinct?.n).toBe(A_REAL_BACKLOG);
	}, LONG_ENOUGH_FOR_A_REAL_BACKLOG);

	it("names the version only once the last part has landed", async () => {
		const parts = Math.ceil(A_REAL_BACKLOG / 500);
		for (let part = 1; part < parts; part++) {
			await sendingPart("/reset", 7, part, parts, [sealed(`task/${part}`)]);
			const midway = await env.RECORDS.prepare("SELECT version FROM store WHERE id = 1").first<{ version: number | null }>();
			expect(midway?.version, `after part ${part}`).toBeNull();
		}
		await sendingPart("/reset", 7, parts, parts, [sealed("task/last")]);

		const settled = await env.RECORDS.prepare("SELECT version FROM store WHERE id = 1").first<{ version: number }>();
		expect(settled?.version).toBe(7);
	}, LONG_ENOUGH_FOR_A_REAL_BACKLOG);

	it("reads back to a phone with nothing missing and nothing twice", async () => {
		await placeWhole(A_REAL_BACKLOG, 7);

		const seen = new Set<string>();
		let cursor = 0;
		let pages = 0;
		for (;;) {
			const answered = await reading(`/records?since=${cursor}`);
			expect(answered.status, `page ${pages + 1}`).toBe(200);
			const read = (await answered.json()) as { records: { k: string }[]; seq: number; more: boolean };
			for (const record of read.records) {
				// A key twice would have the phone write one row over another and never learn of
				// the one it lost.
				expect(seen.has(record.k), `${record.k} came twice`).toBe(false);
				seen.add(record.k);
			}
			// The order belongs to the page rather than to each row, and it is what the next read
			// asks from — a page that did not move it on would have the phone read it again.
			expect(read.seq, `page ${pages + 1} did not move the order on`).toBeGreaterThan(cursor);
			cursor = read.seq;
			pages++;
			if (!read.more) break;
			// A backlog this size is a hundred pages; a read that stopped answering would
			// otherwise sit here rather than saying so.
			expect(pages, "the phone is still reading well past the pages this backlog holds").toBeLessThan(A_REAL_BACKLOG);
		}

		expect(seen.size).toBe(A_REAL_BACKLOG);
		expect(pages).toBe(Math.ceil(A_REAL_BACKLOG / 200));
	}, LONG_ENOUGH_FOR_A_REAL_BACKLOG);
});
