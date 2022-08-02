import '@nomiclabs/hardhat-ethers'
import 'hardhat-deploy'
import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'
import { IController, IController__factory, IProduct } from '../types/generated'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { createPayoffDefinition, reuseOrDeployProduct } from '../util'

const EXAMPLE_COORDINATOR_ID = 1

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const coordinatorID = process.env.COORDINATOR_ID ? parseInt(process.env.COORDINATOR_ID) : EXAMPLE_COORDINATOR_ID
  const { deployments, getNamedAccounts, ethers } = hre
  const { get } = deployments
  const { deployer } = await getNamedAccounts()
  const deployerSigner: SignerWithAddress = await ethers.getSigner(deployer)

  // NETWORK CONSTANTS
  const controller: IController = IController__factory.connect((await get('Controller_Proxy')).address, deployerSigner)
  console.log('using Controller at ' + controller.address)

  // Check coordinator owner
  if (deployerSigner.address !== (await controller['owner(uint256)'](coordinatorID))) {
    process.stdout.write('not deploying from coordinator owner address... exiting.')
    return
  }

  const productInfo: IProduct.ProductInfoStruct = {
    name: 'Short Ether',
    symbol: 'SETH',
    payoffDefinition: createPayoffDefinition({ short: true }),
    oracle: (await get('ChainlinkOracle_ETH')).address,
    maintenance: ethers.utils.parseEther('0.30'),
    fundingFee: ethers.utils.parseEther('0.10'),
    makerFee: 0,
    takerFee: 0,
    makerLimit: ethers.utils.parseEther('2500'),
    utilizationCurve: {
      minRate: ethers.utils.parseEther('-1.50'),
      maxRate: ethers.utils.parseEther('1.50'),
      targetRate: ethers.utils.parseEther('-0.25'),
      targetUtilization: ethers.utils.parseEther('0.80'),
    },
  }

  await reuseOrDeployProduct(hre, coordinatorID, controller, productInfo)
}

export default func
func.tags = ['ShortEther']
