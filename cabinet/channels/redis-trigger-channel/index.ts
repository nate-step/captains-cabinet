#!/usr/bin/env bun
/**
 * Redis Trigger Channel — MCP Channel plugin for Founder's Cabinet
 *
 * Subscribes to Redis Streams and pushes triggers into Claude Code
 * sessions instantly via MCP notifications. Replaces /loop polling.
 *
 * Usage: OFFICER_NAME=cos bun run index.ts
 * Or via .mcp.json as an MCP server with claude/channel capability.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createClient } from "redis";

const OFFICER = process.env.OFFICER_NAME || "unknown";
const REDIS_URL = process.env.REDIS_URL || "redis://redis:6379";
const STREAM_KEY = `cabinet:triggers:${OFFICER}`;
const GROUP_NAME = `officer-${OFFICER}`;
const CONSUMER_NAME = "channel";

// Create MCP server with channel capability
const server = new Server(
  { name: "redis-trigger-channel", version: "1.0.0" },
  {
    capabilities: {
      experimental: { "claude/channel": {} },
    },
  }
);

// Create Redis client
const redis = createClient({ url: REDIS_URL });

redis.on("error", (err) => {
  // Silently handle Redis errors — don't crash the channel
  process.stderr.write(`Redis error: ${err.message}\n`);
});

/**
 * Ensure consumer group exists for this officer
 */
async function ensureConsumerGroup(): Promise<void> {
  try {
    await redis.xGroupCreate(STREAM_KEY, GROUP_NAME, "0", { MKSTREAM: true });
  } catch (err: any) {
    // BUSYGROUP = already exists, that's fine
    if (!err.message?.includes("BUSYGROUP")) {
      process.stderr.write(`Consumer group error: ${err.message}\n`);
    }
  }
}

/**
 * Process any pending (unACK'd) messages from previous sessions
 */
async function processPending(): Promise<void> {
  try {
    const pending = await redis.xReadGroup(GROUP_NAME, CONSUMER_NAME, {
      key: STREAM_KEY,
      id: "0",
    }, { COUNT: 50 });

    if (!pending) return;

    for (const stream of pending) {
      for (const msg of stream.messages) {
        const content = msg.message?.message || JSON.stringify(msg.message);
        await pushToSession(content, msg.id);
        await redis.xAck(STREAM_KEY, GROUP_NAME, msg.id);
      }
    }
  } catch (err: any) {
    process.stderr.write(`Pending processing error: ${err.message}\n`);
  }
}

/**
 * Push a trigger message into the Claude Code session
 */
async function pushToSession(content: string, messageId: string): Promise<void> {
  try {
    await server.notification({
      method: "notifications/claude/channel",
      params: {
        content: content,
        meta: {
          source: "redis",
          stream: STREAM_KEY,
          message_id: messageId,
          officer: OFFICER,
        },
      },
    });
  } catch (err: any) {
    process.stderr.write(`Notification error: ${err.message}\n`);
  }
}

/**
 * Main subscription loop — blocks on XREADGROUP waiting for new triggers
 */
async function subscribeLoop(): Promise<void> {
  while (true) {
    try {
      const results = await redis.xReadGroup(GROUP_NAME, CONSUMER_NAME, {
        key: STREAM_KEY,
        id: ">",
      }, { COUNT: 10, BLOCK: 5000 }); // Block for 5 seconds, then retry

      if (!results) continue; // Timeout, no new messages

      for (const stream of results) {
        for (const msg of stream.messages) {
          const content = msg.message?.message || JSON.stringify(msg.message);
          await pushToSession(content, msg.id);
          // Auto-ACK after delivery — the channel IS the delivery mechanism
          await redis.xAck(STREAM_KEY, GROUP_NAME, msg.id);
        }
      }

      // Trim old messages periodically (not every iteration)
      if (Math.random() < 0.1) {
        await redis.xTrim(STREAM_KEY, "MAXLEN", { strategyModifier: "~", threshold: 100 });
      }

    } catch (err: any) {
      if (err.message?.includes("NOGROUP")) {
        await ensureConsumerGroup();
      } else {
        process.stderr.write(`Subscribe error: ${err.message}\n`);
        // Back off on errors
        await new Promise((r) => setTimeout(r, 2000));
      }
    }
  }
}

/**
 * Main entry point
 */
async function main(): Promise<void> {
  // Connect to Redis
  await redis.connect();

  // Ensure consumer group exists
  await ensureConsumerGroup();

  // Connect MCP server via stdio
  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Brief delay for MCP handshake to complete before sending notifications
  await new Promise((r) => setTimeout(r, 1000));

  // Process any pending messages from before restart
  await processPending();

  // Graceful shutdown
  const shutdown = async () => {
    try {
      await redis.disconnect();
    } catch {}
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  // Start the subscription loop
  await subscribeLoop();
}

main().catch((err) => {
  process.stderr.write(`Fatal: ${err.message}\n`);
  process.exit(1);
});
