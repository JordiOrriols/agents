import { describe, expect, it } from "vitest";
import {
  arrangeTasks,
  elapsedSeconds,
  spentTokens,
  formatDuration,
  formatRelative,
  formatTokens,
  isRunnerOnline,
  parseRunMessage,
  type AgentTask,
} from "../tasks";

describe("parseRunMessage", () => {
  const run = {
    kind: "agents-run",
    version: 1,
    model: "ollama/qwen3.6:35b",
    selection: "Research task",
    phases: [{ name: "work", seconds: 2, tokens: 80, tools: ["webfetch: completed"] }],
    answer: "Could not verify live availability.",
    verification: "No verified current source",
    failure: "Objective not achieved",
  };
  const stats = {
    steps: 12,
    compactions: 2,
    compaction_seconds: 90,
    model_seconds: 600,
    tool_seconds: 30,
    tokens_read: 40000,
    tokens_cached: 10000,
    tokens_generated: 2000,
    largest_context: 45000,
    context_limit: 65536,
    tool_calls: 9,
    tool_errors: 3,
    pages_not_found: 2,
    pages_forbidden: 1,
    truncated_outputs: 4,
    repeated_fetches: 1,
    subagents: 1,
    ended: "stop",
    machine: "Apple M1 Max, 64 GB",
    answer_recovered: false,
  };
  it("preserves legacy chat and parses structured run summaries", () => {
    expect(parseRunMessage("A normal reply")).toBeNull();
    expect(parseRunMessage('{"unrelated":true}')).toBeNull();
    expect(parseRunMessage(JSON.stringify(run))).toEqual(run);
  });
  it("keeps the counters of a run", () => {
    const withStats = { ...run, stats };
    expect(parseRunMessage(JSON.stringify(withStats))).toEqual(withStats);
  });
  it("rejects malformed structured histories", () => {
    for (const overrides of [
      { version: 2 },
      { answer: 1 },
      { failure: false },
      { stats: { ...stats, compactions: "many" } },
      { stats: { ...stats, machine: undefined } },
      { phases: [{ name: "unknown", seconds: 0, tokens: 0, tools: [] }] },
      { phases: [{ name: "work", seconds: -1, tokens: 0, tools: [] }] },
      { phases: [{ name: "work", seconds: 1, tokens: 0, tools: ["private tool output"] }] },
    ])
      expect(() => parseRunMessage(JSON.stringify({ ...run, ...overrides }))).toThrow();
  });
});

const task = (id: string, overrides: Partial<AgentTask>): AgentTask => ({
  id,
  workspaceId: "ws-1",
  title: id,
  instructions: id,
  status: "pending",
  plan: "",
  outcome: "",
  error: "",
  secondsSpent: 0,
  tokensGenerated: 0,
  tokensTotal: 0,
  liveTokensGenerated: 0,
  liveTokensTotal: 0,
  largestContext: 0,
  attempts: 0,
  model: "",
  sessionId: null,
  runner: null,
  createdAt: "2026-11-01T09:00:00Z",
  queuedAt: "2026-11-01T09:00:00Z",
  startedAt: null,
  finishedAt: null,
  ...overrides,
});

describe("arrangeTasks", () => {
  it("lists the running task, then the queue in order, then the most recently finished", () => {
    const { queue, done } = arrangeTasks([
      task("old-done", { status: "completed", finishedAt: "2026-11-01T10:00:00Z" }),
      task("second", { queuedAt: "2026-11-01T09:05:00Z" }),
      task("failed", { status: "failed", finishedAt: "2026-11-01T11:00:00Z" }),
      task("running", { status: "running", queuedAt: "2026-11-01T09:30:00Z" }),
      task("first", { queuedAt: "2026-11-01T09:01:00Z" }),
      task("rerun", { queuedAt: "2026-11-01T12:00:00Z", attempts: 1 }),
    ]);
    expect(queue.map((item) => item.id)).toEqual(["running", "first", "second", "rerun"]);
    expect(done.map((item) => item.id)).toEqual(["failed", "old-done"]);
  });

  it("falls back to creation time when tasks were queued together", () => {
    const { queue, done } = arrangeTasks([
      task("b", { createdAt: "2026-11-01T09:02:00Z" }),
      task("a", { createdAt: "2026-11-01T09:01:00Z" }),
      task("y", { status: "completed", createdAt: "2026-11-01T09:01:00Z" }),
      task("z", { status: "completed", createdAt: "2026-11-01T09:02:00Z" }),
    ]);
    expect(queue.map((item) => item.id)).toEqual(["a", "b"]);
    expect(done.map((item) => item.id)).toEqual(["z", "y"]);
  });
});

describe("formatters", () => {
  it("formats durations at a readable precision", () => {
    expect(formatDuration(-3)).toBe("0s");
    expect(formatDuration(42.4)).toBe("42s");
    expect(formatDuration(125)).toBe("2m 05s");
    expect(formatDuration(3 * 3600 + 7 * 60 + 9)).toBe("3h 07m");
  });

  it("formats token counts compactly", () => {
    expect(formatTokens(950, "en")).toBe("950");
    expect(formatTokens(12_345, "en")).toBe("12.3K");
    expect(formatTokens(1_500_000, "en")).toBe("1.5M");
  });

  it("formats times relative to now", () => {
    const now = Date.parse("2026-11-01T12:00:00Z");
    expect(formatRelative("2026-11-01T11:59:50Z", "en", now)).toBe("now");
    expect(formatRelative("2026-11-01T11:55:00Z", "en", now)).toBe("5 minutes ago");
    expect(formatRelative("2026-11-01T09:00:00Z", "en", now)).toBe("3 hours ago");
    expect(formatRelative("2026-10-31T12:00:00Z", "en", now)).toBe("yesterday");
  });
});

describe("elapsedSeconds", () => {
  const now = Date.parse("2026-11-01T12:00:00Z");
  const task = { secondsSpent: 100, startedAt: "2026-11-01T11:59:00Z" } as AgentTask;

  it("adds the run in progress to the time already spent", () => {
    expect(elapsedSeconds({ ...task, status: "running" }, now)).toBe(160);
  });

  it("never goes backwards when the clocks disagree", () => {
    expect(elapsedSeconds({ ...task, status: "running" }, now - 120_000)).toBe(100);
  });

  it("uses the recorded time once the task stops running", () => {
    expect(elapsedSeconds({ ...task, status: "completed" }, now)).toBe(100);
    expect(elapsedSeconds({ ...task, status: "running", startedAt: null }, now)).toBe(100);
  });
});

describe("spentTokens", () => {
  const figures = {
    tokensGenerated: 10,
    tokensTotal: 100,
    liveTokensGenerated: 5,
    liveTokensTotal: 50,
  };

  it("adds what a running task has reported so far", () => {
    expect(spentTokens({ ...task("a", figures), status: "running" })).toEqual({
      generated: 15,
      total: 150,
    });
  });

  it("ignores old live figures once the run ended", () => {
    expect(spentTokens({ ...task("a", figures), status: "completed" })).toEqual({
      generated: 10,
      total: 100,
    });
  });
});

describe("isRunnerOnline", () => {
  const now = Date.parse("2026-11-01T12:00:00Z");
  it("counts a runner online until it misses two checks", () => {
    expect(
      isRunnerOnline({ name: "mac", pollSeconds: 300, lastSeen: "2026-11-01T11:51:00Z" }, now)
    ).toBe(true);
    expect(
      isRunnerOnline({ name: "mac", pollSeconds: 300, lastSeen: "2026-11-01T11:48:00Z" }, now)
    ).toBe(false);
  });
});
