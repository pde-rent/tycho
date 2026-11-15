// SPDX-License-Identifier: LicenseRef-Fynd-License-1.1
pragma solidity ^0.8.26;

import {IExecutor} from "@interfaces/IExecutor.sol";
import {TransferManager} from "../TransferManager.sol";

// WOOFi sPMM pool (WooPPV2) swap. The pool reads the input from its own balance
// change, so the input is transferred to it before the call; there is no
// approval and no callback.
interface IWooPPV2 {
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minToAmount,
        address to,
        address rebateTo
    ) external returns (uint256 realToAmount);
}

error WooFiExecutor__InvalidDataLength();

/// @dev Swap data is the packed `(pool, tokenIn, tokenOut)`. The Dispatcher
/// transfers `amountIn` to the pool (`TransferType.Transfer`) and the pool pays
/// the receiver. The protocol minimum is zero: the router enforces the caller's
/// minimum on the receiver's balance diff.
contract WooFiExecutor is IExecutor {
    uint256 internal constant DATA_LENGTH = 60;

    function fundsExpectedAddress(bytes calldata data)
        external
        pure
        returns (address receiver)
    {
        (receiver,,) = _decodeData(data);
    }

    // slither-disable-next-line locked-ether The router delegatecalls swap, so any ETH it receives is held by the router.
    function swap(uint256 amountIn, bytes calldata data, address receiver)
        external
        payable
    {
        (address pool, address tokenIn, address tokenOut) = _decodeData(data);
        // slither-disable-next-line unused-return The Dispatcher derives the output from balance diffs, not from return values.
        IWooPPV2(pool)
            .swap(tokenIn, tokenOut, amountIn, 0, receiver, address(0));
    }

    function getTransferData(bytes calldata data)
        external
        pure
        returns (
            TransferManager.TransferType transferType,
            address receiver,
            address tokenIn,
            address tokenOut,
            bool outputToRouter
        )
    {
        (receiver, tokenIn, tokenOut) = _decodeData(data);
        transferType = TransferManager.TransferType.Transfer;
        outputToRouter = false;
    }

    function _decodeData(bytes calldata data)
        internal
        pure
        returns (address pool, address tokenIn, address tokenOut)
    {
        if (data.length != DATA_LENGTH) {
            revert WooFiExecutor__InvalidDataLength();
        }
        pool = address(bytes20(data[0:20]));
        tokenIn = address(bytes20(data[20:40]));
        tokenOut = address(bytes20(data[40:60]));
    }
}
