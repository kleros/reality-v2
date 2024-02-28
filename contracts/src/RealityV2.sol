// SPDX-License-Identifier: MIT

/**
 *  @authors: [@unknownunknown1]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity 0.8.18;

import {IArbitrableV2, IArbitratorV2} from "@kleros/kleros-v2-contracts/arbitration/interfaces/IArbitrableV2.sol";
import "@kleros/kleros-v2-contracts/arbitration/interfaces/IDisputeTemplateRegistry.sol";
import "./interfaces/IRealitio.sol";
import "./interfaces/IRealitioArbitrator.sol";

/// @title RealitioProxyV2
/// @dev Realitio proxy contract compatible with V2.
contract RealitioProxyV2 is IRealitioArbitrator, IArbitrableV2 {
    uint256 public constant REFUSE_TO_ARBITRATE_REALITIO = type(uint256).max; // Constant that represents "Refuse to rule" in realitio format.

    IRealitio public immutable override realitio; // Actual implementation of Realitio.
    IArbitratorV2 public immutable arbitrator; // The Kleros arbitrator.
    bytes public arbitratorExtraData; // Required for Kleros arbitrator. First 64 bytes contain subcourtID and the second 64 bytes contain number of votes in the jury.
    string public override metadata; // Metadata for Realitio. See IRealitioArbitrator.

    IDisputeTemplateRegistry public immutable templateRegistry; // The dispute template registry.
    uint256 public templateId; // Dispute template identifier.

    uint256 private constant NUMBER_OF_RULING_OPTIONS = type(uint256).max; // The amount of non 0 choices the arbitrator can give.

    enum Status {
        None, // The question hasn't been requested arbitration yet.
        Disputed, // The question has been requested arbitration.
        Ruled, // The question has been ruled by arbitrator.
        Reported // The answer of the question has been reported to Realitio.
    }

    // To track internal dispute state in this contract.
    struct ArbitrationRequest {
        Status status; // The current status of the question.
        address requester; // The address that requested the arbitration.
        uint256 disputeID; // The ID of the dispute raised in the arbitrator contract.
        uint256 ruling; // The ruling given by the arbitrator.
    }

    mapping(uint256 => ArbitrationRequest) public arbitrationRequests; // Maps a question identifier in uint256 to its arbitration details. Example: arbitrationRequests[uint256(questionID)]
    mapping(uint256 => uint256) public externalIDtoLocalID; // Maps arbitrator dispute identifiers to local identifiers. We use question ids casted to uint256 as local identifier.

    /// @dev Constructor
    /// @param _realitio The address of the Realitio contract.
    /// @param _metadata The metadata required for RealitioArbitrator.
    /// @param _arbitrator The address of the ERC792 arbitrator.
    /// @param _arbitratorExtraData The extra data used to raise a dispute in the ERC792 arbitrator.
    /// @param _templateRegistry The dispute template registry.
    /// @param _templateData The dispute template data.
    /// @param _templateDataMappings The dispute template data mappings.
    constructor(
        IRealitio _realitio,
        string memory _metadata,
        IArbitratorV2 _arbitrator,
        bytes memory _arbitratorExtraData,
        IDisputeTemplateRegistry _templateRegistry,
        string memory _templateData,
        string memory _templateDataMappings
    ) {
        realitio = _realitio;
        metadata = _metadata;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        templateRegistry = _templateRegistry;
        templateId = templateRegistry.setDisputeTemplate("", _templateData, _templateDataMappings);
    }

    /// @dev Request arbitration from Kleros for given _questionID.
    /// @param _questionID The question identifier in Realitio contract.
    /// @param _maxPrevious If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    /// @return disputeID ID of the resulting dispute in arbitrator.
    function requestArbitration(bytes32 _questionID, uint256 _maxPrevious) external payable returns (uint256 disputeID) {
        ArbitrationRequest storage arbitrationRequest = arbitrationRequests[uint256(_questionID)];
        if(arbitrationRequest.status != Status.None) revert ArbitrationAlreadyRequested();

        // Notify Kleros
        disputeID = arbitrator.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, arbitratorExtraData); /* If msg.value is greater than intended number of votes (specified in arbitratorExtraData),
        Kleros will automatically spend excess for additional votes. */
        externalIDtoLocalID[disputeID] = uint256(_questionID);

        // Update internal state
        arbitrationRequest.requester = msg.sender;
        arbitrationRequest.status = Status.Disputed;
        arbitrationRequest.disputeID = disputeID;

        // Notify Realitio
        realitio.notifyOfArbitrationRequest(_questionID, msg.sender, _maxPrevious);
        emit DisputeRequest(arbitrator, disputeID, uint256(_questionID), templateId, "");
    }

    /// @dev Receives ruling from Kleros and enforces it.
    /// @param _disputeID ID of Kleros dispute.
    /// @param _ruling Ruling that is given by Kleros. This needs to be converted to Realitio answer before reporting the answer by shifting by 1.
    function rule(uint256 _disputeID, uint256 _ruling) public override {
        if(IArbitratorV2(msg.sender) != arbitrator) revert ArbitratorOnly();

        uint256 questionID = externalIDtoLocalID[_disputeID];
        ArbitrationRequest storage arbitrationRequest = arbitrationRequests[questionID];

        if(arbitrationRequest.status != Status.Disputed) revert StatusNotDisputed();

        arbitrationRequest.ruling = _ruling;
        arbitrationRequest.status = Status.Ruled;

        emit Ruling(IArbitratorV2(msg.sender), _disputeID, _ruling);
    }

    /// @dev Reports the answer to a specified question from Kleros arbitrator to the Realitio contract.
    /// This can be called by anyone, after the dispute gets a ruling from Kleros.
    /// We can't directly call `assignWinnerAndSubmitAnswerByArbitrator` inside `rule` because last answerer is not stored on chain.
    /// @param _questionID The ID of Realitio question.
    /// @param _lastHistoryHash The history hash given with the last answer to the question in the Realitio contract.
    /// @param _lastAnswerOrCommitmentID The last answer given, or its commitment ID if it was a commitment, to the question in the Realitio contract, in bytes32.
    /// @param _lastAnswerer The last answerer to the question in the Realitio contract.
    function reportAnswer(
        bytes32 _questionID,
        bytes32 _lastHistoryHash,
        bytes32 _lastAnswerOrCommitmentID,
        address _lastAnswerer
    ) external {
        ArbitrationRequest storage arbitrationRequest = arbitrationRequests[uint256(_questionID)];
        if(arbitrationRequest.status != Status.Ruled) revert StatusNotRuled();

        arbitrationRequest.status = Status.Reported;
        // Realitio ruling is shifted by 1 compared to Kleros.
        uint256 realitioRuling = arbitrationRequest.ruling != 0 ? arbitrationRequest.ruling - 1 : REFUSE_TO_ARBITRATE_REALITIO;

        realitio.assignWinnerAndSubmitAnswerByArbitrator(_questionID, bytes32(realitioRuling), arbitrationRequest.requester, _lastHistoryHash, _lastAnswerOrCommitmentID, _lastAnswerer);
    }

    /// @dev Returns arbitration fee by calling arbitrationCost function in the arbitrator contract.
    /// @return fee Arbitration fee that needs to be paid.
    function getDisputeFee(bytes32) external view override returns (uint256 fee) {
        return arbitrator.arbitrationCost(arbitratorExtraData);
    }

    error StatusNotDisputed();
    error StatusNotRuled();
    error ArbitrationAlreadyRequested();
    error ArbitratorOnly();
}