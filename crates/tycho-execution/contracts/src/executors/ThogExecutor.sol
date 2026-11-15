// SPDX-License-Identifier: LicenseRef-Fynd-License-1.1
pragma solidity ^0.8.26;

import {IExecutor} from "@interfaces/IExecutor.sol";
import {TransferManager} from "../TransferManager.sol";

// ThogAMM maker swap on Monad. The AMM pulls `tokenIn` from the caller with
// `transferFrom` and pays `recipient`. `deadlineBlock` is a block number, not a
// timestamp.
interface IThogAMM {
    function makerSwapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadlineBlock
    ) external returns (uint256 amountOut);
}

error ThogExecutor__InvalidDataLength();

/// @dev Swap data is the packed `(amm, tokenIn, tokenOut)`. The AMM debits the
/// router through an approval the Dispatcher grants for the exact `amountIn`
/// (`ProtocolWillDebit`) and pays the receiver directly. The protocol minimum
/// is zero: the router enforces the caller's minimum on the receiver's balance
/// diff.
///
/// The AMM's view quote does not include its execution defense, which depends
/// on the transaction's gas price relative to the block's base fee, so an
/// executed swap can return less than the quote.
contract ThogExecutor is IExecutor {
    uint256 internal constant DATA_LENGTH = 60;

    function fundsExpectedAddress(
        bytes calldata /* data */
    )
        external
        view
        returns (address receiver)
    {
        return msg.sender;
    }

    // slither-disable-next-line locked-ether The router delegatecalls swap, so any ETH it receives is held by the router.
    function swap(uint256 amountIn, bytes calldata data, address receiver)
        external
        payable
    {
        (address amm, address tokenIn, address tokenOut) = _decodeData(data);
        // slither-disable-next-line unused-return The Dispatcher derives the output from balance diffs, not from return values.
        IThogAMM(amm)
            .makerSwapExactInput(
                tokenIn, tokenOut, amountIn, 0, receiver, block.number
            );
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
        transferType = TransferManager.TransferType.ProtocolWillDebit;
        outputToRouter = false;
    }

    function _decodeData(bytes calldata data)
        internal
        pure
        returns (address amm, address tokenIn, address tokenOut)
    {
        if (data.length != DATA_LENGTH) {
            revert ThogExecutor__InvalidDataLength();
        }
        amm = address(bytes20(data[0:20]));
        tokenIn = address(bytes20(data[20:40]));
        tokenOut = address(bytes20(data[40:60]));
    }
}
