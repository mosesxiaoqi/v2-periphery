pragma solidity =0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol';

import '../libraries/UniswapV2Library.sol';
import '../interfaces/V1/IUniswapV1Factory.sol';
import '../interfaces/V1/IUniswapV1Exchange.sol';
import '../interfaces/IUniswapV2Router01.sol';
import '../interfaces/IERC20.sol';
import '../interfaces/IWETH.sol';

contract ExampleFlashSwap is IUniswapV2Callee {
    IUniswapV1Factory immutable factoryV1; // Uniswap V1 工厂合约引用
    address immutable factory; // Uniswap V2 工厂合约地址
    IWETH immutable WETH; // 包装以太币(WETH)合约引用

    constructor(address _factory, address _factoryV1, address router) public {
        factoryV1 = IUniswapV1Factory(_factoryV1);
        factory = _factory;
        // IUniswapV2Router01 是 Uniswap V2 交易路由合约的接口
        // router 是一个 Uniswap V2 Router 合约地址。
        // 通过 router.WETH() 获取 WETH 合约地址
        // WETH() 是 Uniswap V2 Router 的一个 public 方法，返回 WETH 代币的地址
        WETH = IWETH(IUniswapV2Router01(router).WETH());
    }

    // needs to accept ETH from any V1 exchange and WETH. ideally this could be enforced, as in the router,
    // but it's not possible because it requires a call to the v1 factory, which takes too much gas
    receive() external payable {}

    // gets tokens/WETH via a V2 flash swap, swaps for the ETH/tokens on V1, repays V2, and keeps the rest!
    // 这是一个单向的策略，即只能从V2取款，然后在V1交易所中进行交易，最后将剩余的资产返回给V2
    // 这是Uniswap V2 闪电交换回调接口
    // 通过 V2 闪电交换获取代币/WETH，在 V1 上交换，偿还 V2，并保留剩余部分！
    // sender最初发起闪电交换的地址 如果A合约调用v2的swap函数，那么sender就是A合约的地址,有可能uniswapV2Call不在
    // `amount0`: token0 的借入数量
    // `amount1`: token1 的借入数量
    // `data`: 用户自定义数据
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external override {
        address[] memory path = new address[](2);
        uint amountToken; // 代表借入的非 ETH 代币的数量
        uint amountETH; // 代表借入的 ETH (实际是 WETH) 的数量
        {
            // scope for token{0,1}, avoids stack too deep errors
            // 获取指定的交易对的两个token的地址
            address token0 = IUniswapV2Pair(msg.sender).token0();
            address token1 = IUniswapV2Pair(msg.sender).token1();
            // pairFor 内部调用CREATE2计算出交易对合约的地址
            // 判断调用合约的msg.sender是不是V2交易对合约
            assert(msg.sender == UniswapV2Library.pairFor(factory, token0, token1)); // ensure that msg.sender is actually a V2 pair
            // 这是一个单向的策略，只支持借入一种代币的闪电交换
            assert(amount0 == 0 || amount1 == 0); // this strategy is unidirectional
            // 如果 `amount0 == 0`，则借入的是 token1，路径是 token1 → token0
            path[0] = amount0 == 0 ? token0 : token1;
            // 如果 `amount1 == 0`，则借入的是 token0，路径是 token0 → token1
            path[1] = amount0 == 0 ? token1 : token0;
            amountToken = token0 == address(WETH) ? amount1 : amount0;
            amountETH = token0 == address(WETH) ? amount0 : amount1;
        }

        assert(path[0] == address(WETH) || path[1] == address(WETH)); // this strategy only works with a V2 WETH pair
        IERC20 token = IERC20(path[0] == address(WETH) ? path[1] : path[0]);
        // 调用 `getExchange(tokenAddress)` 可以获取该代币的交易所合约地址
        // `IUniswapV1Exchange(...)` - 将返回的地址转换为 `IUniswapV1Exchange` 接口类型
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(factoryV1.getExchange(address(token))); // get V1 exchange

        if (amountToken > 0) {
            // `minETH` 被注释为"滑点参数"
            // 希望至少获得的 ETH 数量 如果交换结果低于这个值，交易会失败
            uint minETH = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            token.approve(address(exchangeV1), amountToken);
            // `exchangeV1.tokenToEthSwapInput` 是 Uniswap V1 交易所合约提供的函数，用于将 ERC20 代币交换为 ETH
            // `uint(-1)`: 交易的截止时间（这里使用 `uint(-1)` 表示最大的 uint 值，实际上意味着"没有截止时间"）
            uint amountReceived = exchangeV1.tokenToEthSwapInput(amountToken, minETH, uint(-1));
            uint amountRequired = UniswapV2Library.getAmountsIn(factory, amountToken, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough ETH back to repay our flash loan
            // 将原生 ETH 转换为包装版本 WETH
            WETH.deposit{value: amountRequired}();
            // 将 WETH 代币转移给 V2 交易对合约
            assert(WETH.transfer(msg.sender, amountRequired)); // return WETH to V2 pair
            // 使用低级调用将利润（ETH）发送给原始发起人
            (bool success, ) = sender.call{value: amountReceived - amountRequired}(new bytes(0)); // keep the rest! (ETH)
            assert(success);
        } else {
            uint minTokens = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            WETH.withdraw(amountETH);
            uint amountReceived = exchangeV1.ethToTokenSwapInput{value: amountETH}(minTokens, uint(-1));
            uint amountRequired = UniswapV2Library.getAmountsIn(factory, amountETH, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough tokens back to repay our flash loan
            assert(token.transfer(msg.sender, amountRequired)); // return tokens to V2 pair
            assert(token.transfer(sender, amountReceived - amountRequired)); // keep the rest! (tokens)
        }
    }
}
