// Shared helpers for the SealedBountyJudge scripts.
// Loads .env, builds viem clients, and exposes a nonce-safe sender.
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const here = dirname(fileURLToPath(import.meta.url));

export function loadEnv() {
  const p = join(here, ".env");
  const out = {};
  if (existsSync(p)) {
    for (const ln of readFileSync(p, "utf-8").split(/\r?\n/)) {
      const t = ln.trim();
      if (!t || t.startsWith("#")) continue;
      const i = t.indexOf("=");
      if (i < 0) continue;
      out[t.slice(0, i).trim()] = t.slice(i + 1).trim();
    }
  }
  return out;
}

export function makeContext() {
  const env = loadEnv();
  const pk = env.PRIVATE_KEY || process.env.PRIVATE_KEY;
  if (!pk || pk.includes("put_your_separate_testnet_key_here")) {
    throw new Error(
      "PRIVATE_KEY not set. Edit scripts/.env with a SEPARATE testnet key."
    );
  }
  const rpc = env.RPC_URL || "https://rpc.ritualfoundation.org";

  const chain = defineChain({
    id: 1979,
    name: "Ritual",
    nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });

  const account = privateKeyToAccount(pk.startsWith("0x") ? pk : `0x${pk}`);
  const reader = createPublicClient({ chain, transport: http(rpc) });
  const signer = createWalletClient({ account, chain, transport: http(rpc) });

  return { env, rpc, chain, account, reader, signer };
}

export function loadArtifact() {
  const p = join(
    here,
    "..",
    "out",
    "SealedBountyJudge.sol",
    "SealedBountyJudge.json"
  );
  const a = JSON.parse(readFileSync(p, "utf-8"));
  return { abi: a.abi, bytecode: a.bytecode.object };
}

// Nonce-safe sender: tracks nonce locally and retries on the public RPC's
// intermittent "nonce too low" / "already known" responses.
export function makeSender(ctx) {
  let nonce;
  const refresh = async () => {
    nonce = await ctx.reader.getTransactionCount({
      address: ctx.account.address,
      blockTag: "pending",
    });
  };
  const looksLikeNonceIssue = (e) => {
    const s = `${e?.shortMessage || e?.message || ""}${JSON.stringify(
      e?.details || ""
    )}`;
    return /nonce/i.test(s) || /already known/i.test(s);
  };
  const run = async (sendFn, label = "tx") => {
    if (nonce === undefined) await refresh();
    for (let attempt = 1; attempt <= 6; attempt++) {
      try {
        const hash = await sendFn(nonce);
        nonce++;
        const rcpt = await ctx.reader.waitForTransactionReceipt({ hash });
        return { hash, rcpt };
      } catch (e) {
        if (looksLikeNonceIssue(e) && attempt < 6) {
          await new Promise((r) => setTimeout(r, 3000));
          await refresh();
          console.log(`  [${label}] nonce retry -> ${nonce}`);
          continue;
        }
        throw e;
      }
    }
  };
  return { run, refresh };
}

// Ritual block.timestamp is in MILLISECONDS. Wait until the chain passes a
// millisecond deadline (with a small buffer) before sending the next tx.
export async function waitForChainTime(ctx, deadlineMs) {
  for (;;) {
    const blk = await ctx.reader.getBlock({ blockTag: "latest" });
    if (blk.timestamp >= deadlineMs + 2000n) return;
    const remaining = Number(deadlineMs + 2000n - blk.timestamp);
    await new Promise((r) => setTimeout(r, Math.min(remaining + 1000, 5000)));
  }
}

export const ADDR = {
  RITUAL_WALLET: "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948",
  TEE_REGISTRY: "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F",
  LLM_PRECOMPILE: "0x0000000000000000000000000000000000000802",
};

export const ritualWalletAbi = [
  {
    name: "deposit",
    type: "function",
    stateMutability: "payable",
    inputs: [{ name: "lockDuration", type: "uint256" }],
    outputs: [],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
];

export const registryAbi = [
  {
    name: "getServicesByCapability",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "capability", type: "uint8" },
      { name: "checkValidity", type: "bool" },
    ],
    outputs: [
      {
        type: "tuple[]",
        components: [
          {
            name: "node",
            type: "tuple",
            components: [
              { name: "paymentAddress", type: "address" },
              { name: "teeAddress", type: "address" },
              { name: "teeType", type: "uint8" },
              { name: "publicKey", type: "bytes" },
              { name: "endpoint", type: "string" },
              { name: "certPubKeyHash", type: "bytes32" },
              { name: "capability", type: "uint8" },
            ],
          },
          { name: "isValid", type: "bool" },
          { name: "workloadId", type: "bytes32" },
        ],
      },
    ],
  },
];
