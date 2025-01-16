// SPDX-License-Identifier: MIT

/**
 *  @authors: [@unknownunknown1, @jaybuidl]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity 0.8.24;

import {IArbitrableV2, IArbitratorV2} from "@kleros/kleros-v2-contracts/arbitration/interfaces/IArbitrableV2.sol";
import {EvidenceModule} from "@kleros/kleros-v2-contracts/arbitration/evidence/EvidenceModule.sol";
import {IDisputeTemplateRegistry} from "@kleros/kleros-v2-contracts/arbitration/interfaces/IDisputeTemplateRegistry.sol";
import {IRealitio} from "./interfaces/IRealitio.sol";
import {IRealitioArbitrator} from "./interfaces/IRealitioArbitrator.sol";

/// @title RealitioProxyV2
/// @dev Realitio proxy contract compatible with V2.
contract RealitioProxyV2 is IRealitioArbitrator, IArbitrableV2 {
    // ************************************* //
    // *         Enums / Structs           * //
    // ************************************* //

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
        uint256 arbitrationParamsIndex; // The index for the arbitration params for the request.
    }

    struct ArbitrationParams {
        IArbitratorV2 arbitrator; // The arbitrator trusted to solve disputes for this request.
        bytes arbitratorExtraData; // The extra data for the trusted arbitrator of this request.
        EvidenceModule evidenceModule; // The evidence module for the arbitrator.
    }

    // ************************************* //
    // *             Storage               * //
    // ************************************* //

    uint256 private constant NUMBER_OF_RULING_OPTIONS = type(uint256).max; // Maximum, the number of choices in a Realitio question is unknown

    IRealitio public immutable override realitio; // Actual implementation of Realitio.
    string public override metadata; // Metadata for Realitio. See IRealitioArbitrator.
    address public governor; // The address that can make changes to the parameters of the contract.
    IDisputeTemplateRegistry public templateRegistry; // The dispute template registry.
    uint256 public templateId; // Dispute template identifier.
    mapping(uint256 questionID => ArbitrationRequest) public arbitrationRequests; // Maps a question identifier in uint256 to its arbitration details. Example: arbitrationRequests[uint256(questionID)]
    mapping(address arbitrator => mapping(uint256 disputeID => uint256 questionID))
        public arbitratorDisputeIDToQuestionID; // Maps a dispute ID to the ID of the question (converted into uint) with the disputed request in the form arbitratorDisputeIDToQuestionID[arbitrator][disputeID].
    ArbitrationParams[] public arbitrationParamsChanges;

    // ************************************* //
    // *        Function Modifiers         * //
    // ************************************* //

    modifier onlyGovernor() {
        if (governor != msg.sender) revert GovernorOnly();
        _;
    }

    // ************************************* //
    // *            Constructor            * //
    // ************************************* //

    /// @dev Constructor
    /// @param _governor The trusted governor of this contract.
    /// @param _realitio The address of the Realitio contract.
    /// @param _metadata The metadata required for RealitioArbitrator.
    /// @param _arbitrator The address of the ERC792 arbitrator.
    /// @param _arbitratorExtraData The extra data used to raise a dispute in the ERC792 arbitrator.
    /// @param _evidenceModule The evidence contract for the arbitrator.
    /// @param _templateRegistry The dispute template registry.
    /// @param _templateData The dispute template data.
    /// @param _templateDataMappings The dispute template data mappings.
    constructor(
        address _governor,
        IRealitio _realitio,
        string memory _metadata,
        IArbitratorV2 _arbitrator,
        bytes memory _arbitratorExtraData,
        EvidenceModule _evidenceModule,
        IDisputeTemplateRegistry _templateRegistry,
        string memory _templateData,
        string memory _templateDataMappings
    ) {
        governor = _governor;
        realitio = _realitio;
        metadata = _metadata;
        templateRegistry = _templateRegistry;
        templateId = templateRegistry.setDisputeTemplate("", _templateData, _templateDataMappings);
        arbitrationParamsChanges.push(
            ArbitrationParams({
                arbitrator: _arbitrator,
                arbitratorExtraData: _arbitratorExtraData,
                evidenceModule: _evidenceModule
            })
        );
    }

    // ************************************* //
    // *             Governance            * //
    // ************************************* //

    /// @dev Changes the governor of the Reality proxy.
    /// @param _governor The address of the new governor.
    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    /// @notice Changes the params related to arbitration.
    /// @param _arbitrator Arbitrator to resolve potential disputes. The arbitrator is trusted to support appeal periods and not reenter.
    /// @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
    /// @param _evidenceModule The evidence module for the arbitrator.
    function changeArbitrationParams(
        IArbitratorV2 _arbitrator,
        bytes calldata _arbitratorExtraData,
        EvidenceModule _evidenceModule
    ) external onlyGovernor {
        arbitrationParamsChanges.push(
            ArbitrationParams({
                arbitrator: _arbitrator,
                arbitratorExtraData: _arbitratorExtraData,
                evidenceModule: _evidenceModule
            })
        );
    }

    /// @dev Changes the address of Template Registry contract.
    /// @param _templateRegistry The new template registry.
    /// @param _templateData The new template data for template registry.
    /// @param _templateDataMappings The new data mappings json.
    function changeTemplateRegistry(
        IDisputeTemplateRegistry _templateRegistry,
        string memory _templateData,
        string memory _templateDataMappings
    ) external onlyGovernor {
        templateRegistry = _templateRegistry;
        templateId = templateRegistry.setDisputeTemplate("", _templateData, _templateDataMappings);
    }

    /// @dev Changes the dispute template.
    /// @param _templateData The new template data for requests.
    /// @param _templateDataMappings The new data mappings json.
    function changeDisputeTemplate(
        string memory _templateData,
        string memory _templateDataMappings
    ) external onlyGovernor {
        templateId = templateRegistry.setDisputeTemplate("", _templateData, _templateDataMappings);
    }

    // ************************************* //
    // *         State Modifiers           * //
    // ************************************* //

    /// @dev Request arbitration from Kleros for given _questionID.
    /// @param _questionID The question identifier in Realitio contract.
    /// @param _maxPrevious If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    /// @return disputeID ID of the resulting dispute in arbitrator.
    function requestArbitration(
        bytes32 _questionID,
        uint256 _maxPrevious
    ) external payable returns (uint256 disputeID) {
        ArbitrationRequest storage arbitrationRequest = arbitrationRequests[uint256(_questionID)];
        if (arbitrationRequest.status != Status.None) revert ArbitrationAlreadyRequested();
        uint256 arbitrationParamsIndex = arbitrationParamsChanges.length - 1;
        IArbitratorV2 arbitrator = arbitrationParamsChanges[arbitrationParamsIndex].arbitrator;
        bytes memory arbitratorExtraData = arbitrationParamsChanges[arbitrationParamsIndex].arbitratorExtraData;

        // Notify Kleros
        // If msg.value is greater than intended number of votes (specified in arbitratorExtraData), Kleros will automatically spend excess for additional votes.
        disputeID = arbitrator.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, arbitratorExtraData);
        arbitratorDisputeIDToQuestionID[address(arbitrator)][disputeID] = uint256(_questionID);

        // Update internal state
        arbitrationRequest.requester = msg.sender;
        arbitrationRequest.status = Status.Disputed;
        arbitrationRequest.disputeID = disputeID;
        arbitrationRequest.arbitrationParamsIndex = arbitrationParamsIndex;

        // Notify Realitio
        realitio.notifyOfArbitrationRequest(_questionID, msg.sender, _maxPrevious);
        emit DisputeRequest(arbitrator, disputeID, uint256(_questionID), templateId, "");
    }

    /// @dev Receives ruling from Kleros and enforces it.
    /// @param _disputeID ID of Kleros dispute.
    /// @param _ruling Ruling that is given by Kleros. This needs to be converted to Realitio answer before reporting the answer by shifting by 1.
    function rule(uint256 _disputeID, uint256 _ruling) public override {
        uint256 questionID = arbitratorDisputeIDToQuestionID[msg.sender][_disputeID];
        ArbitrationRequest storage arbitrationRequest = arbitrationRequests[questionID];
        IArbitratorV2 arbitrator = arbitrationParamsChanges[arbitrationRequest.arbitrationParamsIndex].arbitrator;

        if (IArbitratorV2(msg.sender) != arbitrator) revert ArbitratorOnly();
        if (arbitrationRequest.status != Status.Disputed) revert StatusNotDisputed();

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
        if (arbitrationRequest.status != Status.Ruled) revert StatusNotRuled();

        arbitrationRequest.status = Status.Reported;
        uint256 realitioRuling = _klerosToRealitioRuling(arbitrationRequest.ruling);
        realitio.assignWinnerAndSubmitAnswerByArbitrator(
            _questionID,
            bytes32(realitioRuling),
            arbitrationRequest.requester,
            _lastHistoryHash,
            _lastAnswerOrCommitmentID,
            _lastAnswerer
        );
    }

    // ************************************* //
    // *           Public Views            * //
    // ************************************* //

    /// @dev Returns arbitration fee by calling arbitrationCost function in the arbitrator contract.
    /// @return fee Arbitration fee that needs to be paid.
    function getDisputeFee(bytes32) external view override returns (uint256 fee) {
        uint256 arbitrationParamsIndex = arbitrationParamsChanges.length - 1;
        IArbitratorV2 arbitrator = arbitrationParamsChanges[arbitrationParamsIndex].arbitrator;
        bytes memory arbitratorExtraData = arbitrationParamsChanges[arbitrationParamsIndex].arbitratorExtraData;
        return arbitrator.arbitrationCost(arbitratorExtraData);
    }

    // ************************************* //
    // *            Internal               * //
    // ************************************* //

    /// @dev Converts Kleros ruling to Realitio ruling.
    /// @param _klerosRuling The ruling from Kleros.
    /// @return The ruling in Realitio format.
    function _klerosToRealitioRuling(uint256 _klerosRuling) internal pure returns (uint256) {
        if (_klerosRuling == 0) return type(uint256).max; // Refuse to arbitrate / Invalid
        if (_klerosRuling == 1) return type(uint256).max - 1; // Answered Too Soon
        return _klerosRuling - 1; // Normal answers are shifted by 1
    }

    // ************************************* //
    // *              Errors               * //
    // ************************************* //

    error StatusNotDisputed();
    error StatusNotRuled();
    error ArbitrationAlreadyRequested();
    error ArbitratorOnly();
    error GovernorOnly();
}
