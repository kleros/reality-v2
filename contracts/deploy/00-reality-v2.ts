import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { HomeChains, isSkipped } from "./utils";

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

const deploy: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  // fallback to hardhat node signers on local network
  const deployer = (await getNamedAccounts()).deployer ?? (await hre.ethers.getSigners())[0].address;
  const chainId = Number(await getChainId());
  console.log("deploying to %s with deployer %s", HomeChains[chainId], deployer);

  const klerosCore = await deployments.get("KlerosCore");
  const disputeTemplateRegistry = await deployments.get("DisputeTemplateRegistry");
  const disputeTemplate = disputeTemplateFn(chainId, klerosCore.address);
  const disputeTemplateMappings = "TODO";

  await deploy("RealityV2", {
    from: deployer,
    args: [
      klerosCore.address,
      extraData,
      disputeTemplate,
      disputeTemplateMappings,
      disputeTemplateRegistry.address,
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
