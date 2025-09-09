- addGeneralLiquidity function deleted as uniswap v4 hook already have addliquidity function 
- ONLYOWNER modifier deleted beacuse its not used in any function for now (we can use it in executebatch )
- feeReciept not used and no funds sent to it 
- disable afterSwapReturnDelta as we dont impplement it 
- delete _provideAMMliquidity as its not used at all 
- in _ensurePoolInitialized we dont need to initialize new pools if the pool didnt exist it revert 
- comment _addLiquidityFromDeposit for now as we dont need it rn (ill better design it)
- we need functions to excute and cancel flip order 
- we need to make flip inside the batch some way 
- partial fills not handeld 
- limit order not checked 








// TODO 

Remove unused storage and code to reduce gas costs
Implement proper fee collection in _transferWithFee
Add proper access control with OpenZeppelin's Ownable
Fix ETH handling to use .call() instead of .transfer()
Reconsider hook timing - move limit order processing to afterSwap
Add decimals handling for proper token amount calculations
Implement proper slippage protection with user-configurable limits
Add comprehensive input validation throughout
Fix state consistency issues in execution functions
Simplify price handling to accept normal prices from users

Critical Issues to Address First

ETH transfer failures - could lock user funds
Inconsistent state updates - could lead to accounting errors
Missing access control - security vulnerability
Unfair pricing due to beforeSwap limit order execution