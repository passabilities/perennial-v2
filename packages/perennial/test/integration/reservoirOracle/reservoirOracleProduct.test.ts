import { expect } from 'chai'
import 'hardhat'
import { BigNumber, utils, constants } from 'ethers'

import { InstanceVars, deployProtocol, createProduct, depositTo } from '../helpers/setupHelpers'
import { createPayoffDefinition, expectPositionEq, expectPrePositionEq } from '../../../../common/testutil/types'
import { DataFeedContext } from '../helpers/feedOracleHelper'
import {
  Product__factory,
  ReservoirFeedOracle,
  ReservoirFeedOracle__factory,
  TestnetContractPayoffProvider,
  TestnetContractPayoffProvider__factory,
} from '../../../types/generated'
import { deployments } from 'hardhat'

const VERSION_OFFSET = BigNumber.from('73786976294838209800')
const INITIAL_VERSION = BigNumber.from(1)
const PRODUCT_INFO = {
  name: 'Squeeth',
  symbol: 'SQTH',
  token: constants.AddressZero,
  payoffDefinition: createPayoffDefinition(),
  oracle: '',
  maintenance: utils.parseEther('0.3'),
  fundingFee: utils.parseEther('0.1'),
  makerFee: 0,
  takerFee: 0,
  positionFee: 0,
  makerLimit: utils.parseEther('1'),
  utilizationCurve: {
    minRate: 0,
    maxRate: utils.parseEther('5.00'),
    targetRate: utils.parseEther('0.80'),
    targetUtilization: utils.parseEther('0.80'),
  },
}

describe('Reservoir Oracle Product', () => {
  let instanceVars: InstanceVars
  let oracleFeed: DataFeedContext
  let reservoirOracle: ReservoirFeedOracle
  let baycUSDCPayoffProvider: TestnetContractPayoffProvider

  beforeEach(async () => {
    instanceVars = await deployProtocol()
    const { owner, dsu } = instanceVars
    PRODUCT_INFO.token = dsu.address

    // Reservoir has not deployed their feed adaptor to mainnet, so for now use Chainlink's DPI feed as a standin
    // TODO(arjun): Update this with Reservoir's mainnet deploy
    const baycUSDCFeed = (await deployments.get('ChainlinkDPIFeed')).address
    oracleFeed = new DataFeedContext(baycUSDCFeed, VERSION_OFFSET)
    await oracleFeed.init()

    reservoirOracle = await new ReservoirFeedOracle__factory(owner).deploy(oracleFeed.feed.address, VERSION_OFFSET)
    baycUSDCPayoffProvider = await new TestnetContractPayoffProvider__factory(owner).deploy()
    PRODUCT_INFO.oracle = reservoirOracle.address
    PRODUCT_INFO.payoffDefinition = createPayoffDefinition({ contractAddress: baycUSDCPayoffProvider.address })

    await oracleFeed.next()
  })

  it('creates a product', async () => {
    const { owner, user, controller, treasuryB, dsu } = instanceVars

    await expect(controller.connect(owner).createCoordinator())
      .to.emit(controller, 'CoordinatorCreated')
      .withArgs(1, owner.address)
    await expect(controller.updateCoordinatorTreasury(1, treasuryB.address))
      .to.emit(controller, 'CoordinatorTreasuryPositionUpdated')
      .withArgs(1, treasuryB.address)

    const productAddress = await controller.callStatic.createProduct(1, PRODUCT_INFO)
    const product = Product__factory.connect(productAddress, owner)
    await expect(controller.createProduct(1, PRODUCT_INFO)).to.emit(controller, 'ProductCreated')

    await dsu.connect(user).approve(product.address, utils.parseEther('1000'))
    await product.connect(user).update(0, utils.parseEther('1000'))

    expect(await product['collateral()']()).to.equal(utils.parseEther('1000'))
    expect(await product.shortfall()).to.equal(0)
  })

  it('opens a make position', async () => {
    const POSITION = utils.parseEther('0.0001')
    const { user } = instanceVars

    const product = await createProduct(instanceVars, baycUSDCPayoffProvider, reservoirOracle)
    await depositTo(instanceVars, user, product, utils.parseEther('1000'))

    await expect(product.connect(user).update(POSITION.mul(-1), 0))
      .to.emit(product, 'PositionUpdated')
      .withArgs(user.address, INITIAL_VERSION, POSITION)

    // Check user is in the correct state
    expect(await product.position(user.address)).to.equal(0)
    expect(await product['pre(address)'](user.address)).to.equal(0)
    expect(await product['latestVersion(address)'](user.address)).to.equal(INITIAL_VERSION)

    // Check global state
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION)
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: POSITION, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })
    expectPositionEq(await product.valueAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPositionEq(await product.shareAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })

    // Settle the product with a new oracle version
    await oracleFeed.next()
    await product.settle(constants.AddressZero)

    // Check global post-settlement state
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION.add(1))
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION.add(1)), { maker: POSITION, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: 0, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })

    // Settle user and check state
    await product.settle(user.address)
    expect(await product.position(user.address)).to.equal(POSITION.mul(-1))
    expect(await product['pre(address)'](user.address)).to.equal(0)
    expect(await product['latestVersion(address)'](user.address)).to.equal(INITIAL_VERSION.add(1))
  })

  it('opens multiple make positions', async () => {
    const POSITION = utils.parseEther('0.0001')
    const { user } = instanceVars

    const product = await createProduct(instanceVars, baycUSDCPayoffProvider, reservoirOracle)
    await depositTo(instanceVars, user, product, utils.parseEther('1000'))

    await product.connect(user).update(POSITION.div(2).mul(-1), 0)

    await expect(product.connect(user).update(POSITION.div(2).mul(-1), 0))
      .to.emit(product, 'PositionUpdated')
      .withArgs(user.address, INITIAL_VERSION, POSITION.div(2))

    // Check user is in the correct state
    expect(await product.position(user.address)).to.equal(0)
    expect(await product['pre(address)'](user.address)).to.equal(0)
    expect(await product['latestVersion(address)'](user.address)).to.equal(INITIAL_VERSION)

    // Check global state
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION)
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: POSITION, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })
    expectPositionEq(await product.valueAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPositionEq(await product.shareAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })

    // Settle the product with a new oracle version
    await oracleFeed.next()
    await product.settle(constants.AddressZero)

    // Check global post-settlement state
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION.add(1))
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION.add(1)), { maker: POSITION, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: 0, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })

    // Settle user and check state
    await product.settle(user.address)
    expect(await product.position(user.address)).to.equal(POSITION.mul(-1))
    expect(await product['pre(address)'](user.address)).to.equal(0)
    expect(await product['latestVersion(address)'](user.address)).to.equal(INITIAL_VERSION.add(1))
  })

  it('closes a make position', async () => {
    const OPEN_POSITION = utils.parseEther('0.0001')
    const CLOSE_POSITION = utils.parseEther('0.0001')
    const { user } = instanceVars

    const product = await createProduct(instanceVars, baycUSDCPayoffProvider, reservoirOracle)
    await depositTo(instanceVars, user, product, utils.parseEther('1000'))
    await product.connect(user).update(OPEN_POSITION.mul(-1), 0)

    await expect(product.connect(user).update(CLOSE_POSITION, 0))
      .to.emit(product, 'PositionUpdated')
      .withArgs(user.address, INITIAL_VERSION, CLOSE_POSITION)

    // User state
    expect(await product.maintenance(user.address)).to.equal(0)
    expect(await product.maintenanceNext(user.address)).to.equal(0)
    expect(await product.position(user.address)).to.equal(0)
    expect(await product['pre(address)'](user.address)).to.equal(0)
    expect(await product['latestVersion(address)'](user.address)).to.equal(INITIAL_VERSION)

    // Global State
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION)
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: 0, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })
    expectPositionEq(await product.valueAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPositionEq(await product.shareAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
  })

  it('closes multiple make positions', async () => {
    const OPEN_POSITION = utils.parseEther('0.0001')
    const CLOSE_POSITION = utils.parseEther('0.0001')
    const { user } = instanceVars

    const product = await createProduct(instanceVars, baycUSDCPayoffProvider, reservoirOracle)
    await depositTo(instanceVars, user, product, utils.parseEther('1000'))
    await product.connect(user).update(OPEN_POSITION.mul(-1), 0)
    await product.connect(user).update(CLOSE_POSITION.div(2), 0)

    await expect(product.connect(user).update(CLOSE_POSITION.div(2), 0))
      .to.emit(product, 'PositionUpdated')
      .withArgs(user.address, INITIAL_VERSION, CLOSE_POSITION.div(2))

    // User state
    expect(await product.maintenance(user.address)).to.equal(0)
    expect(await product.maintenanceNext(user.address)).to.equal(0)
    expect(await product.position(user.address)).to.equal(0)
    expect(await product['pre(address)'](user.address)).to.equal(0)
    expect(await product['latestVersion(address)'](user.address)).to.equal(INITIAL_VERSION)

    // Global State
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION)
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: 0, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })
    expectPositionEq(await product.valueAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPositionEq(await product.shareAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
  })

  it('opens a take position', async () => {
    const MAKE_POSITION = utils.parseEther('0.0001')
    const TAKE_POSITION = utils.parseEther('0.00001')
    const { user, userB, chainlinkOracle } = instanceVars

    const product = await createProduct(instanceVars, baycUSDCPayoffProvider, reservoirOracle)
    await depositTo(instanceVars, user, product, utils.parseEther('1000'))
    await depositTo(instanceVars, userB, product, utils.parseEther('1000'))

    await product.connect(user).update(MAKE_POSITION.mul(-1), 0)
    await expect(product.connect(userB).update(TAKE_POSITION, 0))
      .to.emit(product, 'PositionUpdated')
      .withArgs(userB.address, INITIAL_VERSION, TAKE_POSITION)

    // User State
    expect(await product.position(user.address)).to.equal(0)
    expect(await product['pre(address)'](userB.address)).to.equal(TAKE_POSITION)
    expect(await product['latestVersion(address)'](userB.address)).to.equal(INITIAL_VERSION)

    // Global State
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION)
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: MAKE_POSITION, taker: TAKE_POSITION },
      closePosition: { maker: 0, taker: 0 },
    })
    expectPositionEq(await product.valueAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPositionEq(await product.shareAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })

    // One round
    await oracleFeed.next()
    await chainlinkOracle.sync()

    // Another round
    await oracleFeed.next()
    await product.settle(constants.AddressZero)

    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION.add(2))
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION.add(2)), {
      maker: MAKE_POSITION,
      taker: TAKE_POSITION,
    })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: 0, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })
    await product.settle(userB.address)
    expect(await product.position(user.address)).to.equal(TAKE_POSITION)
    expect(await product['pre(address)'](userB.address)).to.equal(0)
    expect(await product['latestVersion(address)'](userB.address)).to.equal(INITIAL_VERSION.add(2))
  })

  it('opens multiple take positions', async () => {
    const MAKE_POSITION = utils.parseEther('0.0001')
    const TAKE_POSITION = utils.parseEther('0.00001')
    const { user, userB, chainlinkOracle } = instanceVars

    const product = await createProduct(instanceVars, baycUSDCPayoffProvider, reservoirOracle)
    await depositTo(instanceVars, user, product, utils.parseEther('1000'))
    await depositTo(instanceVars, userB, product, utils.parseEther('1000'))

    await product.connect(user).update(MAKE_POSITION.mul(-1), 0)
    await product.connect(userB).update(TAKE_POSITION.div(2), 0)

    await expect(product.connect(userB).update(TAKE_POSITION.div(2), 0))
      .to.emit(product, 'PositionUpdated')
      .withArgs(userB.address, INITIAL_VERSION, TAKE_POSITION.div(2))

    // User State
    expect(await product.position(user.address)).to.equal(0)
    expect(await product['pre(address)'](userB.address)).to.equal(TAKE_POSITION)
    expect(await product['latestVersion(address)'](userB.address)).to.equal(INITIAL_VERSION)

    // Global State
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION)
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: MAKE_POSITION, taker: TAKE_POSITION },
      closePosition: { maker: 0, taker: 0 },
    })
    expectPositionEq(await product.valueAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPositionEq(await product.shareAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })

    // One round
    await oracleFeed.next()
    await chainlinkOracle.sync()

    // Another round
    await oracleFeed.next()
    await product.settle(constants.AddressZero)

    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION.add(2))
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION.add(2)), {
      maker: MAKE_POSITION,
      taker: TAKE_POSITION,
    })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: 0, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })
    await product.settle(userB.address)
    expect(await product.position(user.address)).to.equal(TAKE_POSITION)
    expect(await product['pre(address)'](userB.address)).to.equal(0)
    expect(await product['latestVersion(address)'](userB.address)).to.equal(INITIAL_VERSION.add(2))
  })

  it('closes a take position', async () => {
    const OPEN_MAKE_POSITION = utils.parseEther('0.0001')
    const OPEN_TAKE_POSITION = utils.parseEther('0.00001')
    const CLOSE_TAKE_POSITION = utils.parseEther('0.00001')
    const { user, userB } = instanceVars

    const product = await createProduct(instanceVars, baycUSDCPayoffProvider, reservoirOracle)
    await depositTo(instanceVars, user, product, utils.parseEther('1000'))
    await depositTo(instanceVars, userB, product, utils.parseEther('1000'))

    await expect(product.connect(userB).update(OPEN_TAKE_POSITION, 0)).to.be.revertedWith(
      'InsufficientLiquidityError(0)',
    )
    await product.connect(user).update(OPEN_MAKE_POSITION.mul(-1), 0)
    await product.connect(userB).update(OPEN_TAKE_POSITION, 0)

    await expect(product.connect(userB).update(CLOSE_TAKE_POSITION.mul(-1), 0))
      .to.emit(product, 'PositionUpdated')
      .withArgs(userB.address, INITIAL_VERSION, CLOSE_TAKE_POSITION)

    // User State
    expect(await product.maintenance(userB.address)).to.equal(0)
    expect(await product.maintenanceNext(userB.address)).to.equal(0)
    expect(await product.position(user.address)).to.equal(0)
    expect(await product['pre(address)'](userB.address)).to.equal(0)
    expect(await product['latestVersion(address)'](user.address)).to.equal(INITIAL_VERSION)

    // Global State
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION)
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: OPEN_MAKE_POSITION, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })
    expectPositionEq(await product.valueAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPositionEq(await product.shareAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
  })

  it('closes multiple take positions', async () => {
    const OPEN_MAKE_POSITION = utils.parseEther('0.0001')
    const OPEN_TAKE_POSITION = utils.parseEther('0.00001')
    const CLOSE_TAKE_POSITION = utils.parseEther('0.00001')
    const { user, userB } = instanceVars

    const product = await createProduct(instanceVars, baycUSDCPayoffProvider, reservoirOracle)
    await depositTo(instanceVars, user, product, utils.parseEther('1000'))
    await depositTo(instanceVars, userB, product, utils.parseEther('1000'))

    await expect(product.connect(userB).update(OPEN_TAKE_POSITION, 0)).to.be.revertedWith(
      'InsufficientLiquidityError(0)',
    )
    await product.connect(user).update(OPEN_MAKE_POSITION.mul(-1), 0)
    await product.connect(userB).update(OPEN_TAKE_POSITION, 0)
    await product.connect(userB).update(CLOSE_TAKE_POSITION.div(2).mul(-1), 0)

    await expect(product.connect(userB).update(CLOSE_TAKE_POSITION.div(2).mul(-1), 0))
      .to.emit(product, 'PositionUpdated')
      .withArgs(userB.address, INITIAL_VERSION, CLOSE_TAKE_POSITION.div(2))

    // User State
    expect(await product.maintenance(userB.address)).to.equal(0)
    expect(await product.maintenanceNext(userB.address)).to.equal(0)
    expect(await product.position(user.address)).to.equal(0)
    expect(await product['pre(address)'](userB.address)).to.equal(0)
    expect(await product['latestVersion(address)'](user.address)).to.equal(INITIAL_VERSION)

    // Global State
    expect(await product['latestVersion()']()).to.equal(INITIAL_VERSION)
    expectPositionEq(await product.positionAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPrePositionEq(await product['pre()'](), {
      openPosition: { maker: OPEN_MAKE_POSITION, taker: 0 },
      closePosition: { maker: 0, taker: 0 },
    })
    expectPositionEq(await product.valueAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
    expectPositionEq(await product.shareAtVersion(INITIAL_VERSION), { maker: 0, taker: 0 })
  })

  it('settle no op (gas test)', async () => {
    const { user } = instanceVars

    const product = await createProduct(instanceVars, baycUSDCPayoffProvider, reservoirOracle)

    await product.settle(user.address)
    await product.settle(user.address)
  })
})
