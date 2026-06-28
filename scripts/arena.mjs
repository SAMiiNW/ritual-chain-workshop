// Full on-chain demo of SealedBountyJudge on Ritual Chain WITH a real AI jury
// call (LLM precompile 0x0802). Runs: deploy -> openChallenge -> submitCommitment
// -> revealAnswer -> judgeAll (real LLM) -> finalizeWinner.
import {
  makeContext,
  makeSender,
  loadArtifact,
  waitForChainTime,
  ADDR,
  ritualWalletAbi,
  registryAbi,
} from "./lib.mjs";
import {
  parseEther,
  keccak256,
  toHex,
  encodeAbiParameters,
  parseAbiParameters,
} from "viem";

const ctx = makeContext();
const sender = makeSender(ctx);
const { abi, bytecode } = loadArtifact();

// 30-field LLM request layout (Ritual ritual-dapp-llm skill).
const LLM_LAYOUT = parseAbiParameters(
  [
    "address, bytes[], uint256, bytes[], bytes,",
    "string, string, int256, string, bool, int256, string, string,",
    "uint256, bool, int256, string, bytes, int256, string, string, bool,",
    "int256, bytes, bytes, int256, int256, string, bool,",
    "(string,string,string)",
  ].join("")
);

function buildJuryRequest(executor, criteria, answers) {
  const listed = answers.map((a, i) => `[#${i}] ${a}`).join("\n");
  const messages = [
    {
      role: "system",
      content:
        "You are the jury for a sealed bounty. Score every entry against the " +
        "criteria and return the winning entry number with a one-line reason.",
    },
    { role: "user", content: `Criteria: ${criteria}\n\nEntries:\n${listed}` },
  ];
  return encodeAbiParameters(LLM_LAYOUT, [
    executor,
    [],
    300n,
    [],
    "0x",
    JSON.stringify(messages),
    "zai-org/GLM-4.7-FP8",
    0n,
    "",
    false,
    4096n,
    "",
    "",
    1n,
    true,
    0n,
    "medium",
    "0x",
    -1n,
    "auto",
    "",
    false,
    700n,
    "0x",
    "0x",
    -1n,
    1000n,
    "",
    false,
    ["", "", ""],
  ]);
}

async function main() {
  console.log("Account:", ctx.account.address);
  const native = await ctx.reader.getBalance({ address: ctx.account.address });
  if (native === 0n) throw new Error("Fund the account from the faucet first.");

  // 1) live LLM executor
  const services = await ctx.reader.readContract({
    address: ADDR.TEE_REGISTRY,
    abi: registryAbi,
    functionName: "getServicesByCapability",
    args: [1, true],
  });
  if (!services.length) throw new Error("No live LLM executors");
  const executor = services[0].node.teeAddress;
  console.log("LLM executor:", executor);

  // 2) ensure RitualWallet covers the async jury fee (charged to the EOA)
  const walletBal = await ctx.reader.readContract({
    address: ADDR.RITUAL_WALLET,
    abi: ritualWalletAbi,
    functionName: "balanceOf",
    args: [ctx.account.address],
  });
  if (walletBal < parseEther("0.4")) {
    console.log("Funding RitualWallet (0.5 RITUAL)...");
    await sender.run(
      (nonce) =>
        ctx.signer.writeContract({
          address: ADDR.RITUAL_WALLET,
          abi: ritualWalletAbi,
          functionName: "deposit",
          args: [200000n],
          value: parseEther("0.5"),
          nonce,
        }),
      "deposit"
    );
  } else {
    console.log("RitualWallet already funded:", walletBal.toString(), "wei");
  }

  // 3) deploy
  console.log("Deploying SealedBountyJudge...");
  const dep = await sender.run(
    (nonce) => ctx.signer.deployContract({ abi, bytecode, args: [], nonce }),
    "deploy"
  );
  const arena = dep.rcpt.contractAddress;
  console.log("Arena at:", arena);

  // 4) open challenge — windows are passed in MILLISECONDS because Ritual's
  //    block.timestamp is in ms and the contract adds the window to it.
  console.log("Opening challenge...");
  await sender.run(
    (nonce) =>
      ctx.signer.writeContract({
        address: arena,
        abi,
        functionName: "openChallenge",
        args: [
          "One-line definition of a TEE",
          "accuracy and brevity",
          90000n, // ~90s seal window (ms)
          120000n, // ~120s unseal window (ms)
        ],
        value: parseEther("0.01"),
        nonce,
      }),
    "open"
  );
  const challengeId = 1n;

  // read deadlines (ms) from the contract
  const info = await ctx.reader.readContract({
    address: arena,
    abi,
    functionName: "challengeInfo",
    args: [challengeId],
  });
  const sealDeadline = info[4]; // uint64 ms
  const unsealDeadline = info[5];
  console.log("seal/unseal deadlines (ms):", sealDeadline.toString(), unsealDeadline.toString());

  // 5) seal one entry
  const answer = "A TEE runs code in an attested, isolated enclave.";
  const salt = keccak256(toHex("v2-salt"));
  const seal = await ctx.reader.readContract({
    address: arena,
    abi,
    functionName: "sealOf",
    args: [answer, salt, ctx.account.address, challengeId],
  });
  console.log("Sealing entry (hash only)...");
  await sender.run(
    (nonce) =>
      ctx.signer.writeContract({
        address: arena,
        abi,
        functionName: "submitCommitment",
        args: [challengeId, seal],
        nonce,
      }),
    "seal"
  );

  const beforeReveal = await ctx.reader.readContract({
    address: arena,
    abi,
    functionName: "entryAt",
    args: [challengeId, 0n],
  });
  console.log(
    "During sealing -> unsealed:",
    beforeReveal[2],
    "| stored answer length:",
    (beforeReveal[3] || "").length
  );

  // 6) wait + unseal
  console.log("Waiting for seal deadline...");
  await waitForChainTime(ctx, sealDeadline);
  console.log("Unsealing...");
  await sender.run(
    (nonce) =>
      ctx.signer.writeContract({
        address: arena,
        abi,
        functionName: "revealAnswer",
        args: [challengeId, answer, salt],
        nonce,
      }),
    "unseal"
  );
  const valid = await ctx.reader.readContract({
    address: arena,
    abi,
    functionName: "validEntryCount",
    args: [challengeId],
  });
  console.log("Valid entries:", valid.toString());

  // 7) wait + judge (real LLM)
  console.log("Waiting for unseal deadline...");
  await waitForChainTime(ctx, unsealDeadline);
  const juryReq = buildJuryRequest(executor, "accuracy and brevity", [answer]);
  console.log("Calling judgeAll (real AI jury)...");
  const j = await sender.run(
    (nonce) =>
      ctx.signer.writeContract({
        address: arena,
        abi,
        functionName: "judgeAll",
        args: [challengeId, juryReq],
        gas: 6000000n,
        nonce,
      }),
    "judge"
  );
  console.log("judgeAll status:", j.rcpt.status);

  const afterJudge = await ctx.reader.readContract({
    address: arena,
    abi,
    functionName: "challengeInfo",
    args: [challengeId],
  });
  console.log("stage:", afterJudge[6], "| verdict bytes:", (afterJudge[9].length - 2) / 2);

  // 8) finalize
  console.log("Finalizing winner (#0)...");
  const f = await sender.run(
    (nonce) =>
      ctx.signer.writeContract({
        address: arena,
        abi,
        functionName: "finalizeWinner",
        args: [challengeId, 0n],
        nonce,
      }),
    "finalize"
  );
  console.log("finalizeWinner status:", f.rcpt.status);
  console.log("\nArena demo complete on Ritual Chain.");
  console.log("Explorer: https://explorer.ritualfoundation.org/address/" + arena);
}

main().catch((e) => {
  console.error(e.shortMessage || e.message || e);
  process.exit(1);
});
