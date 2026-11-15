pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Constants} from "../Constants.sol";
import {TestUtils} from "../TestUtils.sol";
import {TychoRouterTestSetup} from "../TychoRouterTestSetup.sol";
import {TransferManager} from "@src/TransferManager.sol";
import {TychoRouter__NegativeSlippage} from "@src/TychoRouterV3.sol";
import {
    ThogExecutor,
    ThogExecutor__InvalidDataLength
} from "@src/executors/ThogExecutor.sol";

contract ThogExecutorExposed is ThogExecutor {
    function decodeParams(bytes calldata data)
        external
        pure
        returns (address amm, address tokenIn, address tokenOut)
    {
        return _decodeData(data);
    }
}

interface IThogAMM {
    function makerQuoteExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 lastPostedBlock);
}

abstract contract ThogTestBase is Constants, TestUtils {
    address internal constant THOG = 0x80c74517BCC2D67fFE02D3ED886796272F647210;
    address internal constant MONAD_USDC =
        0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant MONAD_WMON =
        0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address internal constant MONAD_WETH =
        0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242;
    address internal constant MONAD_CBBTC =
        0xd18B7EC58Cdf4876f6AFebd3Ed1730e4Ce10414b;
    uint256 internal constant FORK_BLOCK = 122522000;

    function _quote(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        (amountOut,) =
            IThogAMM(THOG).makerQuoteExactInput(tokenIn, tokenOut, amountIn);
    }
}

contract ThogExecutorTest is ThogTestBase {
    ThogExecutorExposed thogExecutor;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("monad"), FORK_BLOCK);
        thogExecutor = new ThogExecutorExposed();
    }

    function testDecodeParams() public view {
        (address amm, address tokenIn, address tokenOut) = thogExecutor.decodeParams(
            abi.encodePacked(THOG, MONAD_USDC, MONAD_WMON)
        );

        assertEq(amm, THOG);
        assertEq(tokenIn, MONAD_USDC);
        assertEq(tokenOut, MONAD_WMON);
    }

    function testDecodeParamsInvalidDataLength() public {
        vm.expectRevert(ThogExecutor__InvalidDataLength.selector);
        thogExecutor.decodeParams(abi.encodePacked(THOG, MONAD_USDC));
    }

    function testGetTransferData() public view {
        (
            TransferManager.TransferType transferType,
            address receiver,
            address tokenIn,
            address tokenOut,
            bool outputToRouter
        ) = thogExecutor.getTransferData(
            abi.encodePacked(THOG, MONAD_USDC, MONAD_WMON)
        );

        assertEq(
            uint8(transferType),
            uint8(TransferManager.TransferType.ProtocolWillDebit)
        );
        assertEq(receiver, THOG);
        assertEq(tokenIn, MONAD_USDC);
        assertEq(tokenOut, MONAD_WMON);
        assertFalse(outputToRouter);
    }

    function testFundsExpectedAddress() public view {
        assertEq(
            thogExecutor.fundsExpectedAddress(
                abi.encodePacked(THOG, MONAD_USDC, MONAD_WMON)
            ),
            address(this)
        );
    }

    /// The executor, called as the router would call it under delegatecall:
    /// it holds the input, has approved the AMM and receives nothing back.
    function testSwapPaysReceiverTheQuote() public {
        uint256 amountIn = 1e6;
        uint256 expected = _quote(MONAD_USDC, MONAD_WMON, amountIn);
        assertGt(expected, 0);
        deal(MONAD_USDC, address(thogExecutor), amountIn);
        vm.prank(address(thogExecutor));
        IERC20(MONAD_USDC).approve(THOG, amountIn);

        thogExecutor.swap(
            amountIn, abi.encodePacked(THOG, MONAD_USDC, MONAD_WMON), BOB
        );

        assertEq(IERC20(MONAD_WMON).balanceOf(BOB), expected);
        assertEq(IERC20(MONAD_USDC).balanceOf(address(thogExecutor)), 0);
    }

    function testSwapRevertsForUnlistedToken() public {
        deal(MONAD_USDC, address(thogExecutor), 1e6);
        vm.prank(address(thogExecutor));
        IERC20(MONAD_USDC).approve(THOG, 1e6);

        vm.expectRevert();
        thogExecutor.swap(
            1e6, abi.encodePacked(THOG, MONAD_USDC, address(0xdead)), BOB
        );
    }

    /// The bytes the Rust encoder produces (see `swap_encoder_registry.rs`)
    /// decode to the pair they were built from.
    function testDecodeIntegration() public view {
        bytes memory protocolData =
            loadCallDataFromFile("test_encode_thog_usdc_wmon");

        (address amm, address tokenIn, address tokenOut) =
            thogExecutor.decodeParams(protocolData);

        assertEq(amm, THOG);
        assertEq(tokenIn, MONAD_USDC);
        assertEq(tokenOut, MONAD_WMON);
    }
}

contract TychoRouterForThogTest is TychoRouterTestSetup, ThogTestBase {
    ThogExecutor thogExecutor;

    function getChain() public pure override returns (string memory) {
        return "monad";
    }

    function getForkBlock() public pure override returns (uint256) {
        return FORK_BLOCK;
    }

    function setUp() public override {
        super.setUp();

        thogExecutor = new ThogExecutor();
        address[] memory executors = new address[](1);
        executors[0] = address(thogExecutor);

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
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        bytes memory swap = encodeSingleSwap(
            address(thogExecutor), abi.encodePacked(THOG, tokenIn, tokenOut)
        );

        deal(tokenIn, BOB, amountIn);
        vm.startPrank(BOB);
        IERC20(tokenIn).approve(tychoRouterAddr, amountIn);
        amountOut = tychoRouter.singleSwap(
            amountIn,
            tokenIn,
            tokenOut,
            1,
            minAmountOut,
            BOB,
            noClientFee(),
            swap
        );
        vm.stopPrank();

        assertEq(IERC20(tokenOut).balanceOf(BOB), amountOut);
        assertEq(IERC20(tokenIn).balanceOf(tychoRouterAddr), 0);
        assertEq(IERC20(tokenOut).balanceOf(tychoRouterAddr), 0);
        assertEq(IERC20(tokenIn).allowance(tychoRouterAddr, THOG), 0);
    }

    // forge's default gas price is zero, below the threshold above which the
    // AMM applies its execution defense, so the output equals the view quote.
    function testSingleSwapUsdcToWmon() public {
        uint256 expected = _quote(MONAD_USDC, MONAD_WMON, 1e6);
        assertEq(_singleSwap(MONAD_USDC, MONAD_WMON, 1e6, 1), expected);
    }

    function testSingleSwapWmonToUsdc() public {
        uint256 expected = _quote(MONAD_WMON, MONAD_USDC, 1e18);
        assertEq(_singleSwap(MONAD_WMON, MONAD_USDC, 1e18, 1), expected);
    }

    function testSingleSwapCbbtcToWeth() public {
        uint256 expected = _quote(MONAD_CBBTC, MONAD_WETH, 1e5);
        assertEq(_singleSwap(MONAD_CBBTC, MONAD_WETH, 1e5, 1), expected);
    }

    /// The view quote excludes the execution defense: a transaction paying
    /// well above the base fee can receive less than the quote, never more.
    function testSingleSwapAtHighGasPriceNeverBeatsTheQuote() public {
        uint256 expected = _quote(MONAD_USDC, MONAD_WMON, 1e7);
        vm.fee(1 gwei);
        vm.txGasPrice(3 gwei);
        assertLe(_singleSwap(MONAD_USDC, MONAD_WMON, 1e7, 1), expected);
    }

    function testSingleSwapRevertsBelowMinAmountOut() public {
        uint256 expected = _quote(MONAD_USDC, MONAD_WMON, 1e6);
        bytes memory swap = encodeSingleSwap(
            address(thogExecutor),
            abi.encodePacked(THOG, MONAD_USDC, MONAD_WMON)
        );

        deal(MONAD_USDC, BOB, 1e6);
        vm.startPrank(BOB);
        IERC20(MONAD_USDC).approve(tychoRouterAddr, 1e6);
        vm.expectPartialRevert(TychoRouter__NegativeSlippage.selector);
        tychoRouter.singleSwap(
            1e6,
            MONAD_USDC,
            MONAD_WMON,
            expected + 1,
            expected + 1,
            BOB,
            noClientFee(),
            swap
        );
        vm.stopPrank();
    }
}
