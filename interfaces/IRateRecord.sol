// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRateRecord
/// @notice The rate record of one loan coin: the figure a following rate formula reads. Anyone may
///         deliver a reading or a signer handover signed by the record's signer as an EIP-712 typed
///         instruction (domain name `AERKey`, version `1`, bound to the chain id and to the record's
///         address). The record checks the signature, ranks the ten candidate protocols by deposits,
///         keeps a history of their stated rates and answers one stored centre: the mean of the three
///         leaders' 24-hour average rates. It holds no value and moves no coin.
///
/// Rates are per-second rates scaled by 1e18, the unit of IRateFormula.
interface IRateRecord {
    // ------------------------------------------------------------------ typed instructions

    /// @notice One reading of the ten candidates, as the signer saw them at `asOf`.
    ///         `deposits[i]` is the amount deposited in candidate `i`, used only to rank;
    ///         `rates[i]` is candidate `i`'s borrowing rate per second scaled by 1e18.
    struct Reading {
        bytes32 id;
        uint64 asOf;
        uint256[10] deposits;
        uint256[10] rates;
        uint256 deadline;
    }

    /// @notice A handover of the signer to `next`, effective 72 hours after it is submitted and
    ///         executable for 72 hours after that.
    struct Rotate {
        bytes32 id;
        address next;
        uint256 deadline;
    }

    /// @notice The voiding of the queued handover `handover`, by the current signer, before it executes.
    struct Void {
        bytes32 id;
        bytes32 handover;
        uint256 deadline;
    }

    // ------------------------------------------------------------------ events

    event ReadingAccepted(bytes32 indexed id, uint64 asOf, uint256[3] leaders, uint256 centre);
    event SignerRotationQueued(bytes32 indexed id, address indexed current, address indexed next, uint256 readyAt);
    event SignerRotationVoided(bytes32 indexed id, bytes32 indexed handover);
    event SignerRotated(address indexed previous, address indexed next);

    // ------------------------------------------------------------------ errors

    error BadConfig();
    error AlreadyUsed(bytes32 id);
    error Expired(uint256 deadline);
    error BadSignature();
    error FromTheFuture(uint64 asOf);
    error Stale(uint64 asOf);
    error TooSoon(uint64 asOf, uint64 lastAsOf);
    error RateTooHigh(uint256 i, uint256 rate);
    error TooFewLeaders();
    error ZeroAddress();
    error NotQueued(bytes32 id);
    error NotReady(uint256 readyAt);
    error Voided(bytes32 id);
    error NotKept(uint256 position);

    // ------------------------------------------------------------------ instructions

    /// @notice Accept a reading signed by the current signer. Refused, each with its own error, when
    ///         the deadline is past, the id was used before, the signature is not the signer's, `asOf`
    ///         is after the block, `asOf` is more than an hour before the block, `asOf` is less than
    ///         30 minutes after the last accepted reading, any rate is above the record's highest
    ///         rate, or fewer than three candidates have deposits. A refused reading changes nothing.
    function submitReading(Reading calldata r, bytes calldata signature) external;

    /// @notice Queue a handover of the signer to `r.next`, signed by the current signer. It becomes
    ///         executable 72 hours after this block and stays so for 72 hours more, then is void.
    ///         Until it executes or its window closes, the current signer may void it with a signed
    ///         `Void`; nobody else can stop it.
    function submitRotate(Rotate calldata r, bytes calldata signature) external;

    /// @notice Void the queued handover `v.handover`, signed by the current signer, so that it can
    ///         never execute. Refused, each with its own error, when the deadline is past, the id was
    ///         used before, the signature is not the signer's, `v.handover` names no queued handover,
    ///         or that handover is already void: voided before, queued before the last executed
    ///         handover, which includes the executed one itself, or past its window.
    function submitVoid(Void calldata v, bytes calldata signature) external;

    /// @notice Execute a queued handover once its delay has passed and before its window closes.
    ///         Anyone may call it. Every handover queued before the last executed one is void
    ///         forever, as is every handover the signer voided and every handover whose window has
    ///         closed: one not executed within 72 hours of becoming ready refuses with `Voided(id)`.
    function executeRotate(bytes32 id) external;

    // ------------------------------------------------------------------ digests

    /// @notice The EIP-712 digest the signer signs for a reading.
    function readingDigest(Reading calldata r) external view returns (bytes32);
    /// @notice The EIP-712 digest the signer signs for a handover.
    function rotateDigest(Rotate calldata r) external view returns (bytes32);
    /// @notice The EIP-712 digest the signer signs for the voiding of a handover.
    function voidDigest(Void calldata v) external view returns (bytes32);

    // ------------------------------------------------------------------ what the record answers

    /// @notice The stored centre: the mean of the three leaders' 24-hour average rates at the last
    ///         accepted reading, or the initial centre before the second reading and after a reading
    ///         that ends a silence of more than the record's `STALE_AFTER` (7 days), which starts
    ///         the history afresh. Never reverts and never depends on the clock.
    function centre() external view returns (uint256);
    /// @notice The indexes of the three leaders named by the last accepted reading, in rank order.
    function leaders() external view returns (uint256[3] memory);
    /// @notice `asOf` of the last accepted reading; zero before any.
    function lastAsOf() external view returns (uint64);
    /// @notice The number of readings accepted so far.
    function readingCount() external view returns (uint256);
    /// @notice The ten candidates' labels.
    function candidates() external view returns (bytes32[10] memory);
    /// @notice The current signer.
    function signer() external view returns (address);
    /// @notice One stored reading by its position among all accepted readings (0 is the first ever):
    ///         its `asOf`, its ten rates and its ten running sums. Refused with `NotKept` once the ring
    ///         has overwritten it or before it is made.
    function readingAt(uint256 position)
        external
        view
        returns (uint64 asOf, uint256[10] memory rates, uint256[10] memory sums);
}
