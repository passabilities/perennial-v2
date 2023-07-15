import { BigNumber, BigNumberish, utils, constants } from 'ethers'
import { expect } from 'chai'

export interface Accumulator {
  _value: BigNumberish
}

export interface Position {
  id: BigNumberish
  timestamp: BigNumberish
  maker: BigNumberish
  long: BigNumberish
  short: BigNumberish
  fee: BigNumberish
}

export interface Global {
  currentId: BigNumberish
  protocolFee: BigNumberish
  oracleFee: BigNumberish
  riskFee: BigNumberish
  donation: BigNumberish
}

export interface Local {
  currentId: BigNumberish
  collateral: BigNumberish
  reward: BigNumberish
  protection: BigNumberish
}

export interface Version {
  makerValue: Accumulator
  longValue: Accumulator
  shortValue: Accumulator
  makerReward: Accumulator
  longReward: Accumulator
  shortReward: Accumulator
}

export interface Fee {
  protocol: BigNumberish
  market: BigNumberish
}

export function expectPositionEq(a: Position, b: Position): void {
  expect(a.id).to.equal(b.id, 'Position:Id')
  expect(a.timestamp).to.equal(b.timestamp, 'Position:Timestamp')
  expect(a.maker).to.equal(b.maker, 'Position:Maker')
  expect(a.long).to.equal(b.long, 'Position:Long')
  expect(a.short).to.equal(b.short, 'Position:Short')
  expect(a.fee).to.equal(b.fee, 'Position:Fee')
  // TODO: keeper
}

export function expectGlobalEq(a: Global, b: Global): void {
  expect(a.currentId).to.equal(b.currentId, 'Global:CurrentId')
  expect(a.protocolFee).to.equal(b.protocolFee, 'Global:ProtocolFee')
  expect(a.oracleFee).to.equal(b.oracleFee, 'Global:OracleFee')
  expect(a.riskFee).to.equal(b.riskFee, 'Global:RiskFee')
  expect(a.donation).to.equal(b.donation, 'Global:Donation')
  // TODO: add pAccumulator state
}

export function expectLocalEq(a: Local, b: Local): void {
  expect(a.currentId).to.equal(b.currentId, 'Local:Currentid')
  expect(a.collateral).to.equal(b.collateral, 'Local:Collateral')
  expect(a.reward).to.equal(b.reward, 'Local:Reward')
  expect(a.protection).to.equal(b.protection, 'Local:Protection')
  // TODO: ?
}

export function expectVersionEq(a: Version, b: Version): void {
  expect(a.makerValue._value).to.equal(b.makerValue._value, 'Version:MakerValue')
  expect(a.longValue._value).to.equal(b.longValue._value, 'Version:LongValue')
  expect(a.shortValue._value).to.equal(b.shortValue._value, 'Version:ShortValue')
  expect(a.makerReward._value).to.equal(b.makerReward._value, 'Version:MakerReward')
  expect(a.longReward._value).to.equal(b.longReward._value, 'Version:LongReward')
  expect(a.shortReward._value).to.equal(b.shortReward._value, 'Version:ShortReward')
  // TODO: valid
}

export function parse6decimal(amount: string): BigNumber {
  return utils.parseEther(amount).div(1e12)
}

export class Big18Math {
  public static BASE = constants.WeiPerEther

  public static mul(a: BigNumber, b: BigNumber): BigNumber {
    return a.mul(b).div(this.BASE)
  }

  public static div(a: BigNumber, b: BigNumber): BigNumber {
    return a.mul(this.BASE).div(b)
  }
}

export class Big6Math {
  public static BASE = BigNumber.from(1_000_000)

  public static mul(a: BigNumber, b: BigNumber): BigNumber {
    return a.mul(b).div(this.BASE)
  }

  public static div(a: BigNumber, b: BigNumber): BigNumber {
    return a.mul(this.BASE).div(b)
  }
}
