// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import { TokenHelper } from "../common/TokenHelper.sol";
import { IMemecoin } from "../token/interfaces/IMemecoin.sol";
import { IOutrunAMMPair } from "../common/IOutrunAMMPair.sol";
import { IOutrunAMMRouter } from "../common/IOutrunAMMRouter.sol";
import { OutrunAMMLibraryOnBlast } from "../libraries/OutrunAMMLibraryOnBlast.sol";
import { IMemeverseLauncher } from "./interfaces/IMemeverseLauncher.sol";
import { IMemeLiquidProof } from "../token/interfaces/IMemeLiquidProof.sol";
import { IMemecoinDaoGovernor } from "../governance/interfaces/IMemecoinDaoGovernor.sol";
import { MemecoinYieldVault, IMemecoinYieldVault } from "../yield/MemecoinYieldVault.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title Trapping into the memeverse
 */
contract MemeverseLauncherOnBlast is IMemeverseLauncher, TokenHelper, Ownable {
    using Clones for address;
    using OptionsBuilder for bytes;

    uint256 public constant RATIO = 10000;
    uint256 public constant SWAP_FEERATE = 100;
    address public immutable UPT;
    address public immutable OUTRUN_AMM_ROUTER;
    address public immutable OUTRUN_AMM_FACTORY;

    address public signer;
    address public memeverseRegistrar;
    address public revenuePool;
    address public polImplementation;
    address public vaultImplementation;
    address public yieldDispatcher;
    address public governorImplementation;
    uint256 public minTotalFunds;
    uint256 public fundBasedAmount;
    uint256 public autoBotFeeRate;
    uint128 public oftReceiveGasLimit;
    uint128 public yieldDispatcherGasLimit;

    mapping(address memecoin => uint256) public memecoinToIds;
    mapping(uint256 verseId => Memeverse) public memeverses;
    mapping(uint256 verseId => uint256) public claimableLiquidProofs;
    mapping(uint256 verseId => GenesisFund) public genesisFunds;
    mapping(uint256 verseId => mapping(address account => uint256)) public userTotalFunds;

    constructor(
        address _UPT,
        address _owner,
        address _signer,
        address _revenuePool,
        address _outrunAMMFactory,
        address _outrunAMMRouter,
        address _memeverseRegistrar,
        address _polImplementation,
        address _vaultImplementation,
        address _governorImplementation,
        address _yieldDispatcher,
        uint256 _minTotalFunds,
        uint256 _fundBasedAmount,
        uint256 _autoBotFeeRate,
        uint128 _oftReceiveGasLimit,
        uint128 _yieldDispatcherGasLimit
    ) Ownable(_owner) {
        UPT = _UPT;
        signer = _signer;
        revenuePool = _revenuePool;
        OUTRUN_AMM_ROUTER = _outrunAMMRouter;
        OUTRUN_AMM_FACTORY = _outrunAMMFactory;
        memeverseRegistrar = _memeverseRegistrar;
        polImplementation = _polImplementation;
        vaultImplementation = _vaultImplementation;
        governorImplementation = _governorImplementation;
        yieldDispatcher = _yieldDispatcher;
        minTotalFunds = _minTotalFunds;
        fundBasedAmount = _fundBasedAmount;
        autoBotFeeRate =_autoBotFeeRate;
        oftReceiveGasLimit = _oftReceiveGasLimit;
        yieldDispatcherGasLimit = _yieldDispatcherGasLimit;

        _safeApproveInf(_UPT, _outrunAMMRouter);
    }

    function getVerseIdByMemecoin(address memecoin) external view override returns (uint256 verseId) {
        verseId = memecoinToIds[memecoin];
    }

    function getMemeverseByVerseId(uint256 verseId) external view override returns (Memeverse memory verse) {
        verse = memeverses[verseId];
    }

    function getMemeverseByMemecoin(address memecoin) external view override returns (Memeverse memory verse) {
        verse = memeverses[memecoinToIds[memecoin]];
    }

    function getYieldVaultByVerseId(uint256 verseId) external view override returns (address yieldVault) {
        yieldVault = memeverses[verseId].yieldVault;
    }

    function getYieldVaultByMemecoin(address memecoin) external view override returns (address yieldVault) {
        yieldVault = memeverses[memecoinToIds[memecoin]].yieldVault;
    }

    /**
     * @dev Preview claimable liquidProof of user in stage Locked
     * @param verseId - Memeverse id
     */
    function claimableLiquidProof(uint256 verseId) public view override returns (uint256 claimableAmount) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Locked, NotLockedStage(currentStage));

        uint256 totalFunds = genesisFunds[verseId].totalMemecoinFunds + genesisFunds[verseId].totalLiquidProofFunds;
        uint256 userFunds = userTotalFunds[verseId][msg.sender];
        uint256 totalUserLiquidProof = claimableLiquidProofs[verseId];
        claimableAmount = totalUserLiquidProof * userFunds / totalFunds;
    }

    /**
     * @dev Preview transaction fees for DAO Treasury (UPT) and Yield Vault(Memecoin)
     * @param verseId - Memeverse id
     */
    function previewTransactionFees(uint256 verseId) external view override returns (uint256 UPTFee, uint256 memecoinFee) {
        Memeverse storage verse = memeverses[verseId];
        address memecoin = verse.memecoin;
        IOutrunAMMPair pair = IOutrunAMMPair(OutrunAMMLibraryOnBlast.pairFor(OUTRUN_AMM_FACTORY, memecoin, UPT, SWAP_FEERATE));

        (uint256 amount0, uint256 amount1) = pair.previewMakerFee();
        if (amount0 == 0 && amount1 == 0) return (0, 0);

        address token0 = pair.token0();
        UPTFee = token0 == UPT ? amount0 : amount1;
        memecoinFee = token0 == memecoin ? amount0 : amount1;
    }

    /**
     * @dev Genesis memeverse, deposit UPT to mint memecoin
     * @param verseId - Memeverse id
     * @param amountInUPT - Amount of UPT
     * @notice Approve fund token first
     */
    function genesis(uint256 verseId, uint256 amountInUPT) external override {
        Memeverse storage verse = memeverses[verseId];
        uint256 endTime = verse.endTime;
        uint256 currentTime = block.timestamp;
        require(currentTime < endTime, NotGenesisStage(endTime));

        GenesisFund storage genesisFund = genesisFunds[verseId];
        uint128 totalMemecoinFunds = genesisFund.totalMemecoinFunds;
        uint128 totalLiquidProofFunds = genesisFund.totalLiquidProofFunds;
        uint256 totalFunds = totalMemecoinFunds + totalLiquidProofFunds;
        uint256 maxFund = verse.maxFund;
        address msgSender = msg.sender;
        if (maxFund !=0 && totalFunds + amountInUPT > maxFund) amountInUPT = maxFund - totalFunds;
        _transferIn(UPT, msgSender, amountInUPT);

        uint256 increasedMemecoinFund;
        uint256 increasedLiquidProofFund;
        unchecked {
            increasedLiquidProofFund = amountInUPT / 3;
            increasedMemecoinFund = amountInUPT - increasedLiquidProofFund;
        }

        unchecked {
            genesisFund.totalMemecoinFunds = uint128(totalMemecoinFunds + increasedMemecoinFund);
            genesisFund.totalLiquidProofFunds = uint128(totalLiquidProofFunds + increasedLiquidProofFund);
            userTotalFunds[verseId][msgSender] += amountInUPT;
        }

        emit Genesis(verseId, msgSender, increasedMemecoinFund, increasedLiquidProofFund);
    }

    /**
     * @dev Adaptively change the Memeverse stage
     * @param verseId - Memeverse id
     * @param cancel - true: Cross-chain cancellation of registration, false: No cancellation of registration
     * @notice Only when all chains have entered the refund stage and the symbol in the registration center is
     *         in an unregistrable state, will the "cancel" be true. In the non-refund stage, parameters  such 
     *         as deadline, cancel, v, r, and s are not required.
     */
    function changeStage(
        uint256 verseId, 
        uint256 deadline, 
        bool cancel, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external payable override returns (Stage currentStage) {
        uint256 currentTime = block.timestamp;
        Memeverse storage verse = memeverses[verseId];
        uint256 endTime = verse.endTime;
        require(endTime != 0 && currentTime > endTime, InTheGenesisStage(endTime));

        GenesisFund storage genesisFund = genesisFunds[verseId];
        uint128 totalMemecoinFunds = genesisFund.totalMemecoinFunds;
        uint128 totalLiquidProofFunds = genesisFund.totalLiquidProofFunds;
        address yieldVault;
        if (verse.currentStage == Stage.Genesis) {
            if (totalMemecoinFunds + totalLiquidProofFunds < minTotalFunds) {
                verse.currentStage = Stage.Refund;
                currentStage = Stage.Refund;

                // All chains have entered the refund stage
                require(currentTime < deadline, ExpiredSignature(deadline));
                bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(
                    keccak256(abi.encode(verseId, cancel, block.chainid, deadline))
                );
                require(signer == ECDSA.recover(signedHash, v, r, s), InvalidSigner());

                IMemeverseRegistrationCenter.RegistrationParam memory param;
                param.symbol = verse.symbol;
                IMemeverseRegistrar(memeverseRegistrar).cancelRegistration(verseId, param, msg.sender);
            } else {
                string memory name = verse.name;
                string memory symbol = verse.symbol;
                address creator = verse.creator;
                address memecoin = verse.memecoin;
                bytes32 salt = keccak256(abi.encodePacked(symbol, creator, verseId));

                // Deploy POL
                address liquidProof = polImplementation.cloneDeterministic(salt);
                IMemeLiquidProof(liquidProof).initialize(
                    string(abi.encodePacked("POL-", name)), 
                    string(abi.encodePacked("POL-", symbol)), 
                    18, 
                    memecoin, 
                    address(this)
                );
                verse.liquidProof = liquidProof;

                // Deploy Memecoin Yield Vault on Governance Chain
                address _vaultImplementation = vaultImplementation;
                yieldVault = _vaultImplementation.predictDeterministicAddress(salt);
                if (verse.omnichainIds[0] == block.chainid) {
                    _vaultImplementation.cloneDeterministic(salt);
                    IMemecoinYieldVault(yieldVault).initialize(
                        string(abi.encodePacked("Staked ", name)),
                        string(abi.encodePacked("s", symbol)),
                        memecoin,
                        verseId
                    );
                }
                verse.yieldVault = yieldVault;

                // Deploy Memecoin DAO Governor on Governance Chain
                bytes memory initData = abi.encodeWithSelector(
                    IMemecoinDaoGovernor.initialize.selector,
                    string(abi.encodePacked(name, " DAO")),
                    IVotes(yieldVault),  // voting token
                    1 days,              // voting delay
                    1 weeks,             // voting period
                    10000e18,            // proposal threshold (10000 tokens)
                    30                   // quorum (30%)
                );
                bytes memory proxyBytecode = abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(governorImplementation, initData)
                );
                if (verse.omnichainIds[0] == block.chainid) {
                    verse.governor = Create2.deploy(0, salt, proxyBytecode);
                } else {
                    verse.governor = Create2.computeAddress(salt, keccak256(proxyBytecode));
                }

                // Deploy memecoin liquidity
                uint256 memecoinLiquidityAmount = genesisFunds[verseId].totalMemecoinFunds * fundBasedAmount;
                IMemecoin(memecoin).mint(address(this), memecoinLiquidityAmount);
                _safeApproveInf(memecoin, OUTRUN_AMM_ROUTER);
                _safeApproveInf(UPT, OUTRUN_AMM_ROUTER);
                (,, uint256 memecoinLiquidity) = IOutrunAMMRouter(OUTRUN_AMM_ROUTER).addLiquidity(
                    UPT,
                    memecoin,
                    SWAP_FEERATE,
                    totalMemecoinFunds,
                    memecoinLiquidityAmount,
                    totalMemecoinFunds,
                    memecoinLiquidityAmount,
                    address(this),
                    block.timestamp + 600
                );

                // Mint liquidity proof token and deploy liquid proof liquidity
                IMemeLiquidProof(liquidProof).mint(address(this), memecoinLiquidity);
                _safeApproveInf(liquidProof, OUTRUN_AMM_ROUTER);
                _safeApproveInf(UPT, OUTRUN_AMM_ROUTER);
                uint256 liquidProofLiquidityAmount = memecoinLiquidity / 4;
                IOutrunAMMRouter(OUTRUN_AMM_ROUTER).addLiquidity(
                    UPT,
                    liquidProof,
                    SWAP_FEERATE,
                    totalLiquidProofFunds,
                    liquidProofLiquidityAmount,
                    totalLiquidProofFunds,
                    liquidProofLiquidityAmount,
                    address(0),
                    block.timestamp + 600
                );
                claimableLiquidProofs[verseId] = memecoinLiquidity - liquidProofLiquidityAmount;

                verse.currentStage = Stage.Locked;
                currentStage = Stage.Locked;
            }
        } else if (verse.currentStage == Stage.Locked && currentTime > verse.unlockTime) {
            verse.currentStage = Stage.Unlocked;
            currentStage = Stage.Unlocked;
        }

        emit ChangeStage(verseId, currentStage, yieldVault);
    }

    /**
     * @dev Refund UPT after genesis Failed, total omnichain funds didn't meet the minimum funding requirement
     * @param verseId - Memeverse id
     */
    function refund(uint256 verseId) external override returns (uint256 userFunds) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Refund, NotRefundStage(currentStage));
        
        address msgSender = msg.sender;
        userFunds = userTotalFunds[verseId][msgSender];
        require(userFunds > 0, InsufficientUserFunds());
        userTotalFunds[verseId][msgSender] = 0;
        _transferOut(UPT, msgSender, userFunds);
        
        emit Refund(verseId, msgSender, userFunds);
    }

    /**
     * @dev Claim liquidProof in stage Locked
     * @param verseId - Memeverse id
     */
    function claimLiquidProof(uint256 verseId) external returns (uint256 amount) {
        amount = claimableLiquidProof(verseId);
        if (amount != 0) {
            address msgSender = msg.sender;
            userTotalFunds[verseId][msgSender] = 0;
            _transferOut(memeverses[verseId].liquidProof, msgSender, amount);

            emit ClaimLiquidProof(verseId, msgSender, amount);
        }
    }

    /**
     * @dev Burn liquidProof to claim the locked liquidity
     * @param verseId - Memeverse id
     * @param proofTokenAmount - Burned liquid proof token amount
     */
    function redeemLiquidity(uint256 verseId, uint256 proofTokenAmount) external {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Unlocked, NotUnlockedStage(currentStage));

        address msgSender = msg.sender;
        IMemeLiquidProof(verse.liquidProof).burn(msgSender, proofTokenAmount);
        address pair = OutrunAMMLibraryOnBlast.pairFor(OUTRUN_AMM_FACTORY, verse.memecoin, UPT, SWAP_FEERATE);
        _transferOut(pair, msgSender, proofTokenAmount);

        emit RedeemLiquidity(verseId, msgSender, proofTokenAmount);
    }

    /**
     * @dev Redeem transaction fees and distribute them to the owner(UPT) and vault(Memecoin)
     * @param verseId - Memeverse id
     * @param botFeeReceiver - Address of AutoBotFee receiver
     * @notice Anyone who calls this method will be rewarded with AutoBotFee.
     */
    function redeemAndDistributeFees(uint256 verseId, address botFeeReceiver) external payable override returns (uint256 govFee, uint256 memecoinFee, uint256 liquidProofFee, uint256 autoBotFee) {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, PermissionDenied());

        // memecoin pair
        address memecoin = verse.memecoin;
        IOutrunAMMPair memecoinPair = IOutrunAMMPair(OutrunAMMLibraryOnBlast.pairFor(OUTRUN_AMM_FACTORY, memecoin, UPT, SWAP_FEERATE));
        (uint256 amount0, uint256 amount1) = memecoinPair.claimMakerFee();
        address token0 = memecoinPair.token0();
        uint256 UPTFee = token0 == UPT ? amount0 : amount1;
        memecoinFee = token0 == memecoin ? amount0 : amount1;

        // liquidProof pair
        address liquidProof = verse.liquidProof;
        IOutrunAMMPair liquidProofPair = IOutrunAMMPair(OutrunAMMLibraryOnBlast.pairFor(OUTRUN_AMM_FACTORY, liquidProof, UPT, SWAP_FEERATE));
        (uint256 amount2, uint256 amount3) = liquidProofPair.claimMakerFee();
        address token2 = liquidProofPair.token0();
        UPTFee = token2 == UPT ? UPTFee + amount2 : UPTFee + amount3;
        liquidProofFee = token2 == liquidProof ? amount2 : amount3;

        if (UPTFee == 0 && memecoinFee == 0 && liquidProofFee == 0) return (0, 0, 0, 0);

        // Protocol fee(liquidProofFee)
        if (liquidProofFee != 0) _transferOut(liquidProof, revenuePool, liquidProofFee);

        // AutoBot Fee
        autoBotFee = UPTFee * autoBotFeeRate / RATIO;
        if (autoBotFee != 0) _transferOut(UPT, botFeeReceiver, autoBotFee);
        
        uint32 govEndpointId = IMemeverseRegistrar(memeverseRegistrar).getEndpointId(verse.omnichainIds[0]);
        // Memecoin DAO Treasury income(UPTFee)
        govFee = UPTFee - autoBotFee;

        SendParam memory sendUPTParam;
        MessagingFee memory govMessagingFee;
        if (govFee != 0) {
            bytes memory receiveOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(oftReceiveGasLimit, 0);
            sendUPTParam = SendParam({
                dstEid: govEndpointId,
                to: bytes32(uint256(uint160(verse.governor))),
                amountLD: govFee,
                minAmountLD: 0,
                extraOptions: receiveOptions,
                composeMsg: abi.encode(),
                oftCmd: abi.encode()
            });
            govMessagingFee = IOFT(UPT).quoteSend(sendUPTParam, false);
        }

        // Memecoin Yield Vault income(memecoinFee)
        SendParam memory sendYieldParam;
        MessagingFee memory yieldMessagingFee;
        if (memecoinFee != 0) {
            bytes memory yieldDispatcherOptions = OptionsBuilder.newOptions()
                .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
                .addExecutorLzComposeOption(0, yieldDispatcherGasLimit, 0);
            sendYieldParam = SendParam({
                dstEid: govEndpointId,
                to: bytes32(uint256(uint160(yieldDispatcher))),
                amountLD: memecoinFee,
                minAmountLD: 0,
                extraOptions: yieldDispatcherOptions,
                composeMsg: hex"01",
                oftCmd: abi.encode()
            });
            yieldMessagingFee = IOFT(memecoin).quoteSend(sendYieldParam, false);
        }

        require(msg.value >= govMessagingFee.nativeFee + yieldMessagingFee.nativeFee, InsufficientLzFee());
        if (govFee != 0) IOFT(UPT).send(sendUPTParam, govMessagingFee, msg.sender);
        if (memecoinFee != 0) IOFT(memecoin).send(sendYieldParam, yieldMessagingFee, msg.sender);
        
        emit RedeemAndDistributeFees(verseId, botFeeReceiver, govFee, memecoinFee, liquidProofFee, autoBotFee);
    }

    /**
     * @dev register memeverse
     * @param _name - Name of memecoin
     * @param _symbol - Symbol of memecoin
     * @param uri - IPFS URI of memecoin icon
     * @param creator - The creator of memeverse
     * @param memecoin - Omnichain memecoin address
     * @param uniqueId - Unique verseId
     * @param endTime - Genesis stage end time
     * @param unlockTime - Unlock time of liquidity
     * @param maxFund - Max fundraising(UPT) limit, if 0 => no limit
     * @param omnichainIds - ChainIds of the token's omnichain(EVM)
     */
    function registerMemeverse(
        string calldata _name,
        string calldata _symbol,
        string calldata uri,
        address creator,
        address memecoin,
        uint256 uniqueId,
        uint64 endTime,
        uint64 unlockTime,
        uint128 maxFund,
        uint32[] calldata omnichainIds
    ) external override {
        require(msg.sender == memeverseRegistrar, PermissionDenied());

        Memeverse memory verse = Memeverse(
            _name, 
            _symbol, 
            uri, 
            creator, 
            memecoin, 
            address(0), 
            address(0), 
            address(0),
            maxFund,
            endTime,
            unlockTime, 
            omnichainIds,
            Stage.Genesis
        );
        memeverses[uniqueId] = verse;
        memecoinToIds[memecoin] = uniqueId;

        emit RegisterMemeverse(uniqueId, verse);
    }

    /**
     * @dev Set memeverse registrar
     * @param _registrar - Memeverse registrar address
     */
    function setMemeverseRegistrar(address _registrar) external override onlyOwner {
        require(_registrar != address(0), ZeroInput());

        memeverseRegistrar = _registrar;
    }

    /**
     * @dev Set revenuePool
     * @param _revenuePool - Revenue verse address
     */
    function setRevenuePool(address _revenuePool) external override onlyOwner {
        require(_revenuePool != address(0), ZeroInput());

        revenuePool = _revenuePool;
    }

    /**
     * @dev Set min totalFunds in launch verse
     * @param _minTotalFunds - Min totalFunds
     */
    function setMinTotalFund(uint256 _minTotalFunds) external override onlyOwner {
        require(_minTotalFunds != 0, ZeroInput());

        minTotalFunds = _minTotalFunds;
    }

    /**
     * @dev Set token mint amount based fund
     * @param _fundBasedAmount - Token mint amount based fund
     */
    function setFundBasedAmount(uint256 _fundBasedAmount) external override onlyOwner {
        require(_fundBasedAmount != 0, ZeroInput());

        fundBasedAmount = _fundBasedAmount;
    }

    /**
     * @dev Set AutoBot fee rate 
     * @param _autoBotFeeRate - AutoBot fee rate
     */
    function setAutoBotFeeRate(uint256 _autoBotFeeRate) external override onlyOwner {
        require(_autoBotFeeRate < RATIO, FeeRateOverFlow());

        autoBotFeeRate = _autoBotFeeRate;
    }

    /**
     * @dev Set off-chain signer
     * @param _signer - Address of new signer
     */
    function setSigner(address _signer) external override onlyOwner {
        require(_signer != address(0), ZeroInput());

        signer = _signer;
    }

    /**
     * @dev Set POL implementation logic contract
     * @param _polImplementation - Address of polImplementation
     */
    function setPolImplementation(address _polImplementation) external override onlyOwner {
        require(_polImplementation != address(0), ZeroInput());

        polImplementation = _polImplementation;
    }

    /**
     * @dev Set Vault implementation logic contract
     * @param _vaultImplementation - Address of vaultImplementation
     */
    function setVaultImplementation(address _vaultImplementation) external override onlyOwner {
        require(_vaultImplementation != address(0), ZeroInput());

        vaultImplementation = _vaultImplementation;
    }

    /**
     * @dev Set memecoin DAO governor implementation logic contract
     * @param _governorImplementation - Address of governorImplementation
     */
    function setGovernorImplementation(address _governorImplementation) external override onlyOwner {
        require(_governorImplementation != address(0), ZeroInput());

        governorImplementation = _governorImplementation;
    }

    /**
     * @dev Set memecoin _yieldDispatcher contract
     * @param _yieldDispatcher - Address of _yieldDispatcher
     */
    function setYieldDispatcher(address _yieldDispatcher) external override onlyOwner {
        require(_yieldDispatcher != address(0), ZeroInput());

        yieldDispatcher = _yieldDispatcher;
    }

    /**
     * @dev Set gas limits for OFT receive and yield dispatcher
     * @param _oftReceiveGasLimit - Gas limit for OFT receive
     * @param _yieldDispatcherGasLimit - Gas limit for yield dispatcher
     */
    function setGasLimits(uint128 _oftReceiveGasLimit, uint128 _yieldDispatcherGasLimit) external override onlyOwner {
        require(_oftReceiveGasLimit > 0 && _yieldDispatcherGasLimit > 0, ZeroInput());

        oftReceiveGasLimit = _oftReceiveGasLimit;
        yieldDispatcherGasLimit = _yieldDispatcherGasLimit;
    }
}
