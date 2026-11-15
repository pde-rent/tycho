pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Constants} from "../Constants.sol";
import {TestUtils} from "../TestUtils.sol";
import {TychoRouterTestSetup} from "../TychoRouterTestSetup.sol";
import {TransferManager} from "@src/TransferManager.sol";
import {TychoRouter__NegativeSlippage} from "@src/TychoRouterV3.sol";
import {
    PoeExecutor,
    PoeExecutor__InvalidCallback,
    PoeExecutor__InvalidDataLength
} from "@src/executors/PoeExecutor.sol";

contract PoeExecutorExposed is PoeExecutor {
    function decodeParams(bytes calldata data)
        external
        pure
        returns (address pool, address tokenIn, address tokenOut, bool swapXtoY)
    {
        return _decodeData(data);
    }
}

interface IPoePoolView {
    function getTokens() external view returns (address x, address y);

    function getQuote(bool swapXtoY, uint256 amountIn)
        external
        view
        returns (
            uint256 amountOut,
            uint256 actualAmountIn,
            uint256 feeIn,
            uint256 feeOut
        );
}

/// The WMON/USDC pool: WMON is token X, USDC token Y.
abstract contract PoeTestBase is Constants, TestUtils {
    address internal constant POOL = 0x02A8A16613a421EabaD6861fF6d8159f6D5EDB8f;
    address internal constant MONAD_USDC =
        0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant MONAD_WMON =
        0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address internal constant MONAD_WETH =
        0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242;
    uint256 internal constant FORK_BLOCK = 122522000;
    bytes4 internal constant SWAP_CALLBACK = 0xfa483e72;

    /// Packed swap data: the pool, both tokens and the direction flag.
    function _data(address tokenIn, address tokenOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(POOL, tokenIn, tokenOut, tokenIn == MONAD_WMON);
    }

    function _quote(address tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        uint256 actualAmountIn;
        (amountOut, actualAmountIn,,) =
            IPoePoolView(POOL).getQuote(tokenIn == MONAD_WMON, amountIn);
        // A partial fill reverts in the executor, so only full fills are
        // compared.
        assertEq(actualAmountIn, amountIn, "partial fill");
    }
}

contract PoeExecutorTest is PoeTestBase {
    PoeExecutorExposed poeExecutor;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("monad"), FORK_BLOCK);
        poeExecutor = new PoeExecutorExposed();
    }

    function testPoolTokenOrder() public view {
        (address x, address y) = IPoePoolView(POOL).getTokens();
        assertEq(x, MONAD_WMON);
        assertEq(y, MONAD_USDC);
    }

    function testDecodeParams() public view {
        (address pool, address tokenIn, address tokenOut, bool swapXtoY) =
            poeExecutor.decodeParams(_data(MONAD_WMON, MONAD_USDC));

        assertEq(pool, POOL);
        assertEq(tokenIn, MONAD_WMON);
        assertEq(tokenOut, MONAD_USDC);
        assertTrue(swapXtoY);
    }

    function testDecodeParamsInvalidDataLength() public {
        vm.expectRevert(PoeExecutor__InvalidDataLength.selector);
        poeExecutor.decodeParams(abi.encodePacked(POOL, MONAD_WMON, MONAD_USDC));
    }

    function testGetTransferData() public view {
        (
            TransferManager.TransferType transferType,
            address receiver,
            address tokenIn,
            address tokenOut,
            bool outputToRouter
        ) = poeExecutor.getTransferData(_data(MONAD_WMON, MONAD_USDC));

        assertEq(uint8(transferType), uint8(TransferManager.TransferType.None));
        assertEq(receiver, address(0));
        assertEq(tokenIn, MONAD_WMON);
        assertEq(tokenOut, MONAD_USDC);
        assertFalse(outputToRouter);
    }

    function testGetCallbackTransferData() public view {
        (TransferManager.TransferType transferType, address receiver) = poeExecutor.getCallbackTransferData(
            abi.encodeWithSelector(
                SWAP_CALLBACK, int256(1), int256(-1), bytes("")
            ),
            MONAD_WMON,
            POOL
        );

        assertEq(
            uint8(transferType), uint8(TransferManager.TransferType.Transfer)
        );
        assertEq(receiver, POOL);
    }

    function testGetCallbackTransferDataRejectsOtherSelector() public {
        vm.expectRevert(PoeExecutor__InvalidCallback.selector);
        poeExecutor.getCallbackTransferData(
            abi.encodeWithSelector(
                bytes4(0xdeadbeef), int256(1), int256(-1), bytes("")
            ),
            MONAD_WMON,
            POOL
        );
    }

    function testFundsExpectedAddress() public view {
        assertEq(
            poeExecutor.fundsExpectedAddress(_data(MONAD_WMON, MONAD_USDC)),
            address(this)
        );
    }

    /// No swap is running, so no pool is allowed to call back.
    function testCallbackOutsideSwapReverts() public {
        vm.expectRevert(PoeExecutor__InvalidCallback.selector);
        poeExecutor.handleCallback(
            abi.encodeWithSelector(
                SWAP_CALLBACK, int256(1), int256(-1), bytes("")
            )
        );
    }

    /// The bytes the Rust encoder produces (see `lfj_poe.rs`) decode to the
    /// pair and direction they were built from.
    function testDecodeIntegration() public view {
        bytes memory xToY = loadCallDataFromFile("test_encode_poe_wmon_usdc");
        assertEq(xToY, _data(MONAD_WMON, MONAD_USDC));
        (,,, bool swapXtoY) = poeExecutor.decodeParams(xToY);
        assertTrue(swapXtoY);

        bytes memory yToX = loadCallDataFromFile("test_encode_poe_usdc_wmon");
        assertEq(yToX, _data(MONAD_USDC, MONAD_WMON));
        (,,, swapXtoY) = poeExecutor.decodeParams(yToX);
        assertFalse(swapXtoY);
    }
}

contract TychoRouterForPoeTest is TychoRouterTestSetup, PoeTestBase {
    PoeExecutor poeExecutor;

    function getChain() public pure override returns (string memory) {
        return "monad";
    }

    function getForkBlock() public pure override returns (uint256) {
        return FORK_BLOCK;
    }

    function setUp() public override {
        super.setUp();

        poeExecutor = new PoeExecutor();
        address[] memory executors = new address[](1);
        executors[0] = address(poeExecutor);

        // Activate the executor at the fork block's own timestamp: the pool
        // reads its oracle against block.timestamp.
        vm.warp(forkTimestamp - tychoRouter.DELAY_EXECUTOR_ACTIVATION());
        vm.prank(EXECUTOR_SETTER);
        tychoRouter.setExecutors(executors);
        vm.warp(forkTimestamp);
    }

    function _swapCall(
        address tokenIn,
        address tokenOut,
        bytes memory venueData,
        uint256 amountIn,
        uint256 expectedAmountOut,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        deal(tokenIn, BOB, amountIn);
        vm.startPrank(BOB);
        IERC20(tokenIn).approve(tychoRouterAddr, amountIn);
        amountOut = tychoRouter.singleSwap(
            amountIn,
            tokenIn,
            tokenOut,
            expectedAmountOut,
            minAmountOut,
            BOB,
            noClientFee(),
            encodeSingleSwap(address(poeExecutor), venueData)
        );
        vm.stopPrank();
    }

    function _checkSwap(address tokenIn, address tokenOut, uint256 amountIn)
        internal
    {
        uint256 expected = _quote(tokenIn, amountIn);
        assertGt(expected, 0);

        uint256 amountOut = _swapCall(
            tokenIn, tokenOut, _data(tokenIn, tokenOut), amountIn, 1, 1
        );

        assertEq(amountOut, expected);
        assertEq(IERC20(tokenOut).balanceOf(BOB), expected);
        assertEq(IERC20(tokenIn).balanceOf(tychoRouterAddr), 0);
        assertEq(IERC20(tokenOut).balanceOf(tychoRouterAddr), 0);
    }

    function testSingleSwapWmonToUsdc() public {
        _checkSwap(MONAD_WMON, MONAD_USDC, 100e18);
    }

    function testSingleSwapUsdcToWmon() public {
        _checkSwap(MONAD_USDC, MONAD_WMON, 5e6);
    }

    /// The Rust encoder's bytes execute in both directions.
    function testSingleSwapWithEncodedData() public {
        bytes memory xToY = loadCallDataFromFile("test_encode_poe_wmon_usdc");
        uint256 expected = _quote(MONAD_WMON, 100e18);
        assertEq(
            _swapCall(MONAD_WMON, MONAD_USDC, xToY, 100e18, 1, 1), expected
        );

        bytes memory yToX = loadCallDataFromFile("test_encode_poe_usdc_wmon");
        expected = _quote(MONAD_USDC, 5e6);
        assertEq(_swapCall(MONAD_USDC, MONAD_WMON, yToX, 5e6, 1, 1), expected);
    }

    function testSingleSwapRevertsBelowMinAmountOut() public {
        uint256 expected = _quote(MONAD_WMON, 100e18);
        deal(MONAD_WMON, BOB, 100e18);
        vm.startPrank(BOB);
        IERC20(MONAD_WMON).approve(tychoRouterAddr, 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                TychoRouter__NegativeSlippage.selector, expected, expected + 1
            )
        );
        tychoRouter.singleSwap(
            100e18,
            MONAD_WMON,
            MONAD_USDC,
            expected + 1,
            expected + 1,
            BOB,
            noClientFee(),
            encodeSingleSwap(
                address(poeExecutor), _data(MONAD_WMON, MONAD_USDC)
            )
        );
        vm.stopPrank();
    }

    /// A direction flag that contradicts the tokens makes the pool owe the
    /// other token, so the callback pays the wrong side and the swap reverts.
    function testSingleSwapRevertsOnWrongDirection() public {
        bytes memory wrongDirection =
            abi.encodePacked(POOL, MONAD_WMON, MONAD_USDC, false);
        deal(MONAD_WMON, BOB, 100e18);
        vm.startPrank(BOB);
        IERC20(MONAD_WMON).approve(tychoRouterAddr, 100e18);

        vm.expectRevert(PoeExecutor__InvalidCallback.selector);
        tychoRouter.singleSwap(
            100e18,
            MONAD_WMON,
            MONAD_USDC,
            1,
            1,
            BOB,
            noClientFee(),
            encodeSingleSwap(address(poeExecutor), wrongDirection)
        );
        vm.stopPrank();
    }

    /// A pool that cannot fill the whole input owes less than `amountIn`; the
    /// executor reverts rather than leaving the rest in the router.
    function testSingleSwapRevertsOnPartialFill() public {
        uint256 amountIn = 1e24;
        (, uint256 actualAmountIn,,) =
            IPoePoolView(POOL).getQuote(true, amountIn);
        assertLt(actualAmountIn, amountIn, "pool still fills the whole input");
        deal(MONAD_WMON, BOB, amountIn);
        vm.startPrank(BOB);
        IERC20(MONAD_WMON).approve(tychoRouterAddr, amountIn);

        vm.expectRevert(PoeExecutor__InvalidCallback.selector);
        tychoRouter.singleSwap(
            amountIn,
            MONAD_WMON,
            MONAD_USDC,
            1,
            1,
            BOB,
            noClientFee(),
            encodeSingleSwap(
                address(poeExecutor), _data(MONAD_WMON, MONAD_USDC)
            )
        );
        vm.stopPrank();
    }

    function testSingleSwapRevertsForTokenOutsideThePool() public {
        deal(MONAD_WETH, BOB, 1e15);
        vm.startPrank(BOB);
        IERC20(MONAD_WETH).approve(tychoRouterAddr, 1e15);

        vm.expectRevert();
        tychoRouter.singleSwap(
            1e15,
            MONAD_WETH,
            MONAD_USDC,
            1,
            1,
            BOB,
            noClientFee(),
            encodeSingleSwap(
                address(poeExecutor),
                abi.encodePacked(POOL, MONAD_WETH, MONAD_USDC, true)
            )
        );
        vm.stopPrank();
    }
}
