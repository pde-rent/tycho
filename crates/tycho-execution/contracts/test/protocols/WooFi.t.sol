pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Constants} from "../Constants.sol";
import {TestUtils} from "../TestUtils.sol";
import {TychoRouterTestSetup} from "../TychoRouterTestSetup.sol";
import {TransferManager} from "@src/TransferManager.sol";
import {TychoRouter__NegativeSlippage} from "@src/TychoRouterV3.sol";
import {
    WooFiExecutor,
    WooFiExecutor__InvalidDataLength
} from "@src/executors/WooFiExecutor.sol";

contract WooFiExecutorExposed is WooFiExecutor {
    function decodeParams(bytes calldata data)
        external
        pure
        returns (address pool, address tokenIn, address tokenOut)
    {
        return _decodeData(data);
    }
}

interface IWooPPV2Query {
    function query(address fromToken, address toToken, uint256 fromAmount)
        external
        view
        returns (uint256 toAmount);
}

/// The pool prices one quote token (USDC) against its listed bases; a base to
/// base swap routes through USDC inside one call.
abstract contract WooFiTestBase is Constants, TestUtils {
    address internal constant WOO = 0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4;
    address internal constant MONAD_USDC =
        0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant MONAD_WMON =
        0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address internal constant MONAD_WETH =
        0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242;
    address internal constant MONAD_CBBTC =
        0xd18B7EC58Cdf4876f6AFebd3Ed1730e4Ce10414b;
    address internal constant MONAD_AUSD =
        0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    uint256 internal constant FORK_BLOCK = 122522000;

    function _quote(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        return IWooPPV2Query(WOO).query(tokenIn, tokenOut, amountIn);
    }
}

contract WooFiExecutorTest is WooFiTestBase {
    WooFiExecutorExposed wooFiExecutor;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("monad"), FORK_BLOCK);
        wooFiExecutor = new WooFiExecutorExposed();
    }

    function testDecodeParams() public view {
        (address pool, address tokenIn, address tokenOut) = wooFiExecutor.decodeParams(
            abi.encodePacked(WOO, MONAD_WMON, MONAD_USDC)
        );

        assertEq(pool, WOO);
        assertEq(tokenIn, MONAD_WMON);
        assertEq(tokenOut, MONAD_USDC);
    }

    function testDecodeParamsInvalidDataLength() public {
        vm.expectRevert(WooFiExecutor__InvalidDataLength.selector);
        wooFiExecutor.decodeParams(abi.encodePacked(WOO, MONAD_WMON));
    }

    function testGetTransferData() public view {
        (
            TransferManager.TransferType transferType,
            address receiver,
            address tokenIn,
            address tokenOut,
            bool outputToRouter
        ) = wooFiExecutor.getTransferData(
            abi.encodePacked(WOO, MONAD_WMON, MONAD_USDC)
        );

        assertEq(
            uint8(transferType), uint8(TransferManager.TransferType.Transfer)
        );
        assertEq(receiver, WOO);
        assertEq(tokenIn, MONAD_WMON);
        assertEq(tokenOut, MONAD_USDC);
        assertFalse(outputToRouter);
    }

    function testFundsExpectedAddress() public view {
        assertEq(
            wooFiExecutor.fundsExpectedAddress(
                abi.encodePacked(WOO, MONAD_WMON, MONAD_USDC)
            ),
            WOO
        );
    }

    /// The Dispatcher has already transferred the input to the pool when it
    /// delegatecalls `swap`.
    function testSwapPaysReceiverTheQuote() public {
        uint256 amountIn = 100e18;
        uint256 expected = _quote(MONAD_WMON, MONAD_USDC, amountIn);
        assertGt(expected, 0);
        deal(MONAD_WMON, WOO, IERC20(MONAD_WMON).balanceOf(WOO) + amountIn);

        wooFiExecutor.swap(
            amountIn, abi.encodePacked(WOO, MONAD_WMON, MONAD_USDC), BOB
        );

        assertEq(IERC20(MONAD_USDC).balanceOf(BOB), expected);
    }

    function testSwapRevertsForUnlistedToken() public {
        deal(MONAD_USDC, WOO, IERC20(MONAD_USDC).balanceOf(WOO) + 50e6);

        vm.expectRevert();
        wooFiExecutor.swap(
            50e6, abi.encodePacked(WOO, MONAD_USDC, MONAD_AUSD), BOB
        );
    }

    /// The bytes the Rust encoder produces (see `swap_encoder_registry.rs`)
    /// decode to the pair they were built from.
    function testDecodeIntegration() public view {
        bytes memory protocolData =
            loadCallDataFromFile("test_encode_woofi_wmon_usdc");

        (address pool, address tokenIn, address tokenOut) =
            wooFiExecutor.decodeParams(protocolData);

        assertEq(pool, WOO);
        assertEq(tokenIn, MONAD_WMON);
        assertEq(tokenOut, MONAD_USDC);
    }
}

contract TychoRouterForWooFiTest is TychoRouterTestSetup, WooFiTestBase {
    WooFiExecutor wooFiExecutor;

    function getChain() public pure override returns (string memory) {
        return "monad";
    }

    function getForkBlock() public pure override returns (uint256) {
        return FORK_BLOCK;
    }

    function setUp() public override {
        super.setUp();

        wooFiExecutor = new WooFiExecutor();
        address[] memory executors = new address[](1);
        executors[0] = address(wooFiExecutor);

        // Activate the executor at the fork block's own timestamp: the venue
        // reads its oracle against block.timestamp.
        vm.warp(forkTimestamp - tychoRouter.DELAY_EXECUTOR_ACTIVATION());
        vm.prank(EXECUTOR_SETTER);
        tychoRouter.setExecutors(executors);
        vm.warp(forkTimestamp);
    }

    function _singleSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 expectedAmountOut,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        bytes memory swap = encodeSingleSwap(
            address(wooFiExecutor), abi.encodePacked(WOO, tokenIn, tokenOut)
        );

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
            swap
        );
        vm.stopPrank();

        assertEq(IERC20(tokenOut).balanceOf(BOB), amountOut);
        assertEq(IERC20(tokenIn).balanceOf(tychoRouterAddr), 0);
        assertEq(IERC20(tokenOut).balanceOf(tychoRouterAddr), 0);
    }

    function _checkSwap(address tokenIn, address tokenOut, uint256 amountIn)
        internal
    {
        uint256 expected = _quote(tokenIn, tokenOut, amountIn);
        assertGt(expected, 0);
        assertEq(_singleSwap(tokenIn, tokenOut, amountIn, 1, 1), expected);
    }

    function testSingleSwapWmonToUsdc() public {
        _checkSwap(MONAD_WMON, MONAD_USDC, 100e18);
    }

    function testSingleSwapUsdcToWeth() public {
        _checkSwap(MONAD_USDC, MONAD_WETH, 50e6);
    }

    function testSingleSwapCbbtcToUsdc() public {
        _checkSwap(MONAD_CBBTC, MONAD_USDC, 1e5);
    }

    /// A base to base swap is one pool call, routed through USDC inside it.
    function testSingleSwapWmonToWeth() public {
        _checkSwap(MONAD_WMON, MONAD_WETH, 100e18);
    }

    function _revertingSwap(
        address tokenOut,
        uint256 amountIn,
        uint256 expectedAmountOut,
        uint256 minAmountOut,
        bytes memory expectedRevert
    ) internal {
        bytes memory swap = encodeSingleSwap(
            address(wooFiExecutor), abi.encodePacked(WOO, MONAD_USDC, tokenOut)
        );
        deal(MONAD_USDC, BOB, amountIn);
        vm.startPrank(BOB);
        IERC20(MONAD_USDC).approve(tychoRouterAddr, amountIn);
        if (expectedRevert.length > 0) {
            vm.expectRevert(expectedRevert);
        } else {
            vm.expectRevert();
        }
        tychoRouter.singleSwap(
            amountIn,
            MONAD_USDC,
            tokenOut,
            expectedAmountOut,
            minAmountOut,
            BOB,
            noClientFee(),
            swap
        );
        vm.stopPrank();
    }

    function testSingleSwapRevertsBelowMinAmountOut() public {
        uint256 expected = _quote(MONAD_USDC, MONAD_WETH, 50e6);

        _revertingSwap(
            MONAD_WETH,
            50e6,
            expected + 1,
            expected + 1,
            abi.encodeWithSelector(
                TychoRouter__NegativeSlippage.selector, expected, expected + 1
            )
        );
    }

    function testSingleSwapRevertsForUnlistedToken() public {
        _revertingSwap(MONAD_AUSD, 50e6, 1, 1, "");
    }
}
