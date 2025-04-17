import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { HomeChains, isSkipped } from "./utils";
import { DeploymentName, getContractsEthers } from "@kleros/kleros-v2-contracts";

const disputeTemplateFn = (chainId: number, arbitratorAddress: string) => `{
    "title": "A reality.eth question",
    "description": "A reality.eth question has been raised to arbitration.",
    "question": "{{ question }}",
    "type": "{{ type }}",
    "answers": [
      {
        "title": "Answered Too Soon",
        "description": "Answered Too Soon.",
      },
      {{# answers }}
      {
          "title": "{{ title }}",
          "description": "{{ description }}",
      }{{^ last }},{{/ last }}
      {{/ answers }}
    ],
    "policyURI": "/ipfs/QmZ5XaV2RVgBADq5qMpbuEwgCuPZdRgCeu8rhGtJWLV6yz",
    "frontendUrl": "https://reality.eth.limo/app/#!/question/{{ realityAddress }}-{{ questionId }}",
    "arbitratorChainID": "${chainId}",
    "arbitratorAddress": "${arbitratorAddress}",
    "category": "Oracle",
    "lang": "en_US",
    "specification": "KIP99",
    "version": "1.0"
}`;

// General court, 3 jurors
const extraData =
  "0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000003";

const NETWORK_TO_DEPLOYMENT: Record<string, DeploymentName> = {
  arbitrumSepoliaDevnet: "devnet",
  arbitrumSepolia: "testnet",
  arbitrum: "mainnetNeo",
} as const;

const deploy: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts, getChainId, ethers } = hre;
  const { deploy } = deployments;

  // fallback to hardhat node signers on local network
  const deployer = (await getNamedAccounts()).deployer ?? (await hre.ethers.getSigners())[0].address;
  const chainId = Number(await getChainId());
  console.log("deploying to %s with deployer %s", HomeChains[chainId], deployer);

  const networkName = deployments.getNetworkName();
  const deploymentName = NETWORK_TO_DEPLOYMENT[networkName];

  if (!deploymentName)
    throw new Error(
      `Unsupported network: ${networkName}. Supported networks: ${Object.keys(NETWORK_TO_DEPLOYMENT).join(", ")}`
    );

  const { klerosCore, disputeTemplateRegistry } = await getContractsEthers(ethers.provider, deploymentName);
  const disputeTemplate = disputeTemplateFn(chainId, klerosCore.target as string);
  const disputeTemplateMappings = "TODO";

  await deploy("RealityV2", {
    from: deployer,
    args: [
      klerosCore.target,
      extraData,
      disputeTemplate,
      disputeTemplateMappings,
      disputeTemplateRegistry.target,
      600, // feeTimeout: 10 minutes
    ],
    log: true,
  });
};

deploy.tags = ["RealityV2"];
deploy.skip = async ({ network }) => {
  return isSkipped(network, !HomeChains[network.config.chainId ?? 0]);
};

export default deploy;
