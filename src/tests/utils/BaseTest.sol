// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import {stdMath} from 'forge-std/StdMath.sol';
import {AaveV3Polygon} from 'aave-address-book/AaveV3Polygon.sol';
import {DataTypes} from 'aave-address-book/AaveV3.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IERC20WithPermit} from 'solidity-utils/contracts/oz-common/interfaces/IERC20WithPermit.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';
import {IBaseParaSwapAdapter} from 'src/contracts/interfaces/IBaseParaSwapAdapter.sol';
import {SigUtils} from './SigUtils.sol';

contract BaseTest is Test {
  struct PsPResponse {
    address augustus;
    bytes swapCalldata;
    uint256 srcAmount;
    uint256 destAmount;
    uint256 offset;
  }

  address public user;
  uint256 internal userPrivateKey;

  uint256 constant MAX_SLIPPAGE = 3;

  function setUp() public virtual {
    userPrivateKey = 0xA11CE;
    user = address(vm.addr(userPrivateKey));
  }

  function _fetchPSPRoute(
    address from,
    address to,
    uint256 amount,
    address userAddress,
    bool sell,
    bool max
  ) internal returns (PsPResponse memory) {
    string[] memory inputs = new string[](13);
    inputs[0] = 'node';
    inputs[1] = './scripts/psp.js';
    inputs[2] = vm.toString(block.chainid);
    inputs[3] = vm.toString(from);
    inputs[4] = vm.toString(to);
    inputs[5] = vm.toString(amount);
    inputs[6] = vm.toString(userAddress);
    inputs[7] = sell ? 'SELL' : 'BUY';
    inputs[8] = vm.toString(MAX_SLIPPAGE);
    inputs[9] = vm.toString(max);
    inputs[10] = vm.toString(IERC20Detailed(from).decimals());
    inputs[11] = vm.toString(IERC20Detailed(to).decimals());
    inputs[12] = vm.toString(block.number);

    bytes memory res = vm.ffi(inputs);
    return abi.decode(res, (PsPResponse));
  }

  function _fetchPSPRouteWithoutPspCacheUpdate(
    address from,
    address to,
    uint256 amount,
    address userAddress,
    bool sell,
    bool max
  ) internal returns (PsPResponse memory) {
    string[] memory inputs = new string[](14);
    inputs[0] = 'node';
    inputs[1] = './scripts/psp.js';
    inputs[2] = vm.toString(block.chainid);
    inputs[3] = vm.toString(from);
    inputs[4] = vm.toString(to);
    inputs[5] = vm.toString(amount);
    inputs[6] = vm.toString(userAddress);
    inputs[7] = sell ? 'SELL' : 'BUY';
    inputs[8] = vm.toString(MAX_SLIPPAGE);
    inputs[9] = vm.toString(max);
    inputs[10] = vm.toString(IERC20Detailed(from).decimals());
    inputs[11] = vm.toString(IERC20Detailed(to).decimals());
    inputs[12] = vm.toString(block.number);
    inputs[13] = 'false';

    bytes memory res = vm.ffi(inputs);
    return abi.decode(res, (PsPResponse));
  }

  /**
   * @dev Ensure balances are 0 on the adapter itself
   */
  function _invariant(address adapter, address debtAsset, address newDebtAsset) internal {
    assertEq(IERC20Detailed(debtAsset).balanceOf(address(adapter)), 0, 'LEFTOVER_DEBT_ASSET');
    assertEq(
      IERC20Detailed(newDebtAsset).balanceOf(address(adapter)),
      0,
      'LEFTOVER_NEW_DEBT_ASSET'
    );
  }

  function _withinRange(uint256 a, uint256 b, uint256 diff) internal pure returns (bool) {
    return stdMath.delta(a, b) <= diff;
  }

  /**
   * @dev Ensure the amount offset in ParaSwap calldata is correct
   */
  function _checkAmountInParaSwapCalldata(
    uint256 offset,
    uint256 amount,
    bytes memory swapCalldata
  ) internal {
    uint256 amountAtOffset;
    // Ensure 256 bit (32 bytes) offset value is within bounds of the
    // calldata, not overlapping with the first 4 bytes (function selector).
    assertTrue(offset >= 4 && offset <= swapCalldata.length - 32, 'offset out of range');
    // In memory, swapCalldata consists of a 256 bit length field, followed by
    // the actual bytes data, that is why 32 is added to the byte offset.
    assembly {
      amountAtOffset := mload(add(swapCalldata, add(offset, 32)))
    }

    assertEq(amountAtOffset, amount, 'wrong offset');
  }

  function _getPermit(
    address permitToken,
    address debtSwapAdapter,
    uint256 amount
  ) internal view returns (IBaseParaSwapAdapter.PermitInput memory) {
    IERC20WithPermit token = IERC20WithPermit(permitToken);
    uint256 nonce;
    try IERC20WithPermit(token).nonces(user) returns (uint256 res) {
      nonce = res;
    } catch {
      nonce = IATokenV2(address(token))._nonces(user);
    }

    SigUtils.Permit memory permit = SigUtils.Permit({
      owner: user,
      spender: address(debtSwapAdapter),
      value: amount,
      nonce: nonce,
      deadline: type(uint256).max
    });

    bytes32 digest = SigUtils.getTypedDataHash(permit, token.DOMAIN_SEPARATOR());

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

    return
      IBaseParaSwapAdapter.PermitInput({
        aToken: token,
        value: amount,
        deadline: type(uint256).max,
        v: v,
        r: r,
        s: s
      });
  }
}

interface IATokenV2 {
  function _nonces(address user) external view returns (uint256);
}
