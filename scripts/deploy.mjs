// Deploy SealedBountyJudge to Ritual Chain. Prints the contract address and the
// deploy transaction hash (what the Proof-of-Building form asks for).
import { makeContext, makeSender, loadArtifact } from "./lib.mjs";

const ctx = makeContext();
const sender = makeSender(ctx);
const { abi, bytecode } = loadArtifact();

console.log("Deployer:", ctx.account.address);
console.log("Deploying SealedBountyJudge...");

const { hash, rcpt } = await sender.run(
  (nonce) =>
    ctx.signer.deployContract({ abi, bytecode, args: [], nonce }),
  "deploy"
);

console.log("DEPLOY TX HASH:", hash);
console.log("CONTRACT ADDRESS:", rcpt.contractAddress);
console.log("Block:", rcpt.blockNumber.toString(), "Status:", rcpt.status);
console.log(
  "\nExplorer (contract): https://explorer.ritualfoundation.org/address/" +
    rcpt.contractAddress
);
console.log(
  "Explorer (deploy tx): https://explorer.ritualfoundation.org/tx/" + hash
);
