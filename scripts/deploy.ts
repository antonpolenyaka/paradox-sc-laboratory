import { ethers } from "hardhat";
import { RoleAdminChangedEvent } from '../typechain-types/@openzeppelin/contracts/access/IAccessControl';
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

async function main() {
  let deployer: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let charlie: SignerWithAddress;
  let rewardsPool: SignerWithAddress;
  [deployer, alice, bob, charlie, rewardsPool] = await ethers.getSigners();

  // USDT
  const USDT = await ethers.getContractFactory("USDT");
  const usdt = await USDT.deploy();
  await usdt.deployed();
  console.log(`USDT deployed to ${usdt.address}`);

  // Paradox
  const ParadoxToken = await ethers.getContractFactory("ParadoxToken");
  const paradoxToken = await ParadoxToken.deploy();
  await paradoxToken.deployed();
  console.log(`ParadoxToken deployed to ${paradoxToken.address}`);

  // Parapad
  const Parapad = await ethers.getContractFactory("Parapad");
  const parapad = await Parapad.deploy(usdt.address, paradoxToken.address);
  await parapad.deployed();
  console.log(`Parapad deployed to ${parapad.address}`);

  // Utilities
  const Utilities = await ethers.getContractFactory("Utilities");
  const utilities = await Utilities.deploy();
  await utilities.deployed();
  console.log(`Utilities deployed to ${utilities.address}`);

  // StakePool
  const StakePool = await ethers.getContractFactory("StakePool");
  // address _para, uint256 _rewardsPerSecond, address _rewardsPoolAddress
  const para = parapad.address;
  const rewardsPerSecond = BigInt((5000 / (24 * 60 * 60)) * 10 ** 18);
  const rewardsPoolAddress = rewardsPool.address;
  const stakePool = await StakePool.deploy(para, rewardsPerSecond, rewardsPoolAddress);
  await stakePool.deployed();
  console.log(`StakePool deployed to ${stakePool.address}`);

  // Lock example
  const currentTimestampInSeconds = Math.round(Date.now() / 1000);
  const unlockTime = currentTimestampInSeconds + 60;
  const lockedAmount = ethers.utils.parseEther("0.001");
  const Lock = await ethers.getContractFactory("Lock");
  const lock = await Lock.deploy(unlockTime, { value: lockedAmount });
  await lock.deployed();
  console.log(
    `Lock with ${ethers.utils.formatEther(lockedAmount)}ETH and unlock timestamp ${unlockTime} deployed to ${lock.address}`
  );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
