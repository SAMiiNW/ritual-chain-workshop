// Prints the public address + balance for the .env key (never the key itself).
import { makeContext } from "./lib.mjs";
import { formatEther } from "viem";

const ctx = makeContext();
console.log("PUBLIC ADDRESS:", ctx.account.address);
const bal = await ctx.reader.getBalance({ address: ctx.account.address });
console.log("BALANCE:", formatEther(bal), "RITUAL");
if (bal === 0n) {
  console.log("\n=> Fund this address: https://faucet.ritualfoundation.org");
} else {
  console.log("\n=> Funded. Run: npm run deploy  (then  npm run demo)");
}
