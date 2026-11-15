// SPDX-License-Identifier: LicenseRef-Fynd-License-1.1
pragma solidity ^0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IExecutor} from "@interfaces/IExecutor.sol";
import {ICallback} from "@interfaces/ICallback.sol";
import {TransferManager} from "../TransferManager.sol";

// LFJ POE pool swap. The pool pays `recipient` first, then calls
// `swapCallback(int256,int256,bytes)` on the caller with the deltas of its
// token X and token Y (positive = owed to the pool, negative = paid out). The
// caller pays the input to the pool inside the callback and returns the
// callback's own selector, left-aligned in one word; the pool reverts without
// it.
interface IPoePool {
    function swap(
        address recipient,
        bool swapXtoY,
        uint256 amountIn,
        bytes calldata data
    ) external returns (int256 amountXDelta, int256 amountYDelta);
}

error PoeExecutor__InvalidDataLength();
error PoeExecutor__InvalidCallback();

/// @dev Swap data is the packed `(pool, tokenIn, tokenOut, swapXtoY)`, with
/// `swapXtoY` set when `tokenIn` is the pool's token X. The router pays the
/// hop's whole `amountIn` in the callback. A pool that fills only part of the
/// input owes less than `amountIn`, and the callback then reverts instead of
/// letting the swap complete.
contract PoeExecutor is IExecutor, ICallback {
    using SafeCast for int256;
    // One directive per slot type: Slither 0.11.6 can fail to analyse a
    // contract that uses `using TransientSlot for *`.
    using TransientSlot for TransientSlot.AddressSlot;
    using TransientSlot for TransientSlot.Uint256Slot;

    uint256 private constant DATA_LENGTH = 61;
    // swapCallback(int256,int256,bytes)
    bytes4 private constant _POE_CALLBACK_SELECTOR = 0xfa483e72;

    TransientSlot.AddressSlot private constant _CURRENT_POE_POOL_SLOT =
        TransientSlot.AddressSlot.wrap(keccak256("PoeExecutor#CURRENT_POOL"));
    TransientSlot.Uint256Slot private constant _CURRENT_POE_AMOUNT_IN_SLOT =
        TransientSlot.Uint256Slot.wrap(keccak256("PoeExecutor#AMOUNT_IN"));

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
        (address pool,,, bool swapXtoY) = _decodeData(data);

        _CURRENT_POE_POOL_SLOT.tstore(pool);
        _CURRENT_POE_AMOUNT_IN_SLOT.tstore(amountIn);
        // slither-disable-next-line unused-return The Dispatcher derives the output from balance diffs, not from return values.
        IPoePool(pool).swap(receiver, swapXtoY, amountIn, "");
        _CURRENT_POE_POOL_SLOT.tstore(address(0));
        _CURRENT_POE_AMOUNT_IN_SLOT.tstore(0);
    }

    function handleCallback(bytes calldata data)
        public
        view
        returns (bytes memory)
    {
        (int256 deltaX, int256 deltaY) = _decodeCallback(data);
        if (msg.sender != _CURRENT_POE_POOL_SLOT.tload()) {
            revert PoeExecutor__InvalidCallback();
        }

        // Exactly the hop amount is owed on one side and nothing on the other.
        uint256 owedX = deltaX > 0 ? deltaX.toUint256() : 0;
        uint256 owedY = deltaY > 0 ? deltaY.toUint256() : 0;
        uint256 amountIn = _CURRENT_POE_AMOUNT_IN_SLOT.tload();
        bool exactInput = (owedX == amountIn && owedY == 0)
            || (owedY == amountIn && owedX == 0);
        if (!exactInput) {
            revert PoeExecutor__InvalidCallback();
        }

        return abi.encodePacked(_POE_CALLBACK_SELECTOR, bytes28(0));
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
        (, tokenIn, tokenOut,) = _decodeData(data);
        transferType = TransferManager.TransferType.None;
        receiver = address(0);
        outputToRouter = false;
    }

    function getCallbackTransferData(
        bytes calldata data,
        address, /* tokenIn */
        address caller
    )
        external
        pure
        returns (TransferManager.TransferType transferType, address receiver)
    {
        _decodeCallback(data);
        transferType = TransferManager.TransferType.Transfer;
        receiver = caller;
    }

    function _decodeData(bytes calldata data)
        internal
        pure
        returns (address pool, address tokenIn, address tokenOut, bool swapXtoY)
    {
        if (data.length != DATA_LENGTH) {
            revert PoeExecutor__InvalidDataLength();
        }
        pool = address(bytes20(data[0:20]));
        tokenIn = address(bytes20(data[20:40]));
        tokenOut = address(bytes20(data[40:60]));
        swapXtoY = uint8(data[60]) > 0;
    }

    function _decodeCallback(bytes calldata data)
        internal
        pure
        returns (int256 deltaX, int256 deltaY)
    {
        if (data.length < 68 || bytes4(data[:4]) != _POE_CALLBACK_SELECTOR) {
            revert PoeExecutor__InvalidCallback();
        }
        (deltaX, deltaY) = abi.decode(data[4:68], (int256, int256));
    }
}
