import test from "node:test";
import assert from "node:assert/strict";
import { filterNodes, rankNodes, validateController } from "../index.js";

test("filters node names with include and exclude regular expressions", () => {
  const nodes = ["日本-OS-1", "日本-FW-TEST", "美国-US-1", "JP-Tokyo"];
  assert.deepEqual(filterNodes(nodes, "日本|JP", "TEST"), ["日本-OS-1", "JP-Tokyo"]);
});

test("an empty filter includes every node", () => {
  assert.deepEqual(filterNodes(["SG", "US"], ""), ["SG", "US"]);
});

test("ranks reachable candidates and applies maxDelay", () => {
  const ranked = rankNodes(["slow", "fast", "down"], { slow: 400, fast: 80, down: 0 }, 300);
  assert.deepEqual(ranked, [{ name: "fast", delay: 80 }]);
});

test("reports an invalid filter clearly", () => {
  assert.throws(() => filterNodes(["JP"], "["), /Invalid filter regular expression/);
});

test("allows local HTTP controllers", () => {
  assert.equal(validateController("http://127.0.0.1:9090/"), "http://127.0.0.1:9090");
});

test("rejects insecure remote controllers unless explicitly allowed", () => {
  assert.throws(() => validateController("http://192.168.1.2:9090"), /must use HTTPS/);
  assert.equal(validateController("http://192.168.1.2:9090", true), "http://192.168.1.2:9090");
});
