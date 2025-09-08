import { stakeAddress } from "../constant/address";
import stakeABI from "../abi/stake.json";
import { privateKey, provider } from "../constant/constant";
import { Contract, Wallet } from "ethers";

async function unStake() {
  const signer: Wallet = new Wallet(privateKey, provider);
  const stake = new Contract(stakeAddress, stakeABI, signer);
  const tx = await stake["unStake"](
    Number(await stake["stakedCount"](signer)) - 1
  );
  console.log("tx hash", tx.hash);

  const receipt = await tx.wait();

  console.log("tx", receipt);
}

unStake();
