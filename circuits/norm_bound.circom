pragma circom 2.1.6;

// ZK-FedChain norm-bound circuit (draft).
//
// A client proves, without revealing its update, that it knows a quantized
// LoRA update delta[D] and a salt such that
//   (1) every coordinate is a signed 16-bit value:      -2^15 <= delta[i] < 2^15
//   (2) the squared L2 norm is within the agreed bound: sum(delta[i]^2) <= normBoundSq
//   (3) commitment = Poseidon(chain(packed delta), salt, roundId, client)
//
// Public signals (order expected by RoundManager / IGroth16Verifier):
//   [0] commitment   (output)
//   [1] normBoundSq  (public input, set by the contract config)
//   [2] roundId      (public input, binds the proof to one round)
//   [3] client       (public input, uint160 address of the submitter)
//
// Negative coordinates are encoded as field elements p - |x|; squaring them
// in the field gives the correct non-negative square.

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/bitify.circom";
include "../node_modules/circomlib/circuits/comparators.circom";

// D    : number of update coordinates (LoRA parameters) in the circuit
// PACK : coordinates packed into one field element before hashing (15 x 16 bits = 240 bits < 254)
template NormBound(D, PACK) {
    // ---- public ----
    signal input normBoundSq;
    signal input roundId;
    signal input client;
    signal output commitment;

    // ---- private ----
    signal input delta[D];
    signal input salt;

    // (1) Range check: shifted = delta + 2^15 must fit in 16 bits.
    signal shifted[D];
    component range[D];
    for (var i = 0; i < D; i++) {
        shifted[i] <== delta[i] + 32768;
        range[i] = Num2Bits(16);
        range[i].in <== shifted[i];
    }

    // (2) Squared norm. With D <= 2^15 the sum stays below 2^45, so a 64-bit comparison is safe.
    signal sq[D];
    signal acc[D + 1];
    acc[0] <== 0;
    for (var i = 0; i < D; i++) {
        sq[i] <== delta[i] * delta[i];
        acc[i + 1] <== acc[i] + sq[i];
    }
    component withinBound = LessEqThan(64);
    withinBound.in[0] <== acc[D];
    withinBound.in[1] <== normBoundSq;
    withinBound.out === 1;

    // (3) Commitment: pack PACK shifted coordinates per field element,
    //     hash the chunks in a chain, then bind salt, round and client.
    var NCHUNK = (D + PACK - 1) \ PACK;
    signal packed[NCHUNK];
    for (var j = 0; j < NCHUNK; j++) {
        var lc = 0;
        for (var k = 0; k < PACK; k++) {
            if (j * PACK + k < D) {
                lc += shifted[j * PACK + k] * (2 ** (16 * k));
            }
        }
        packed[j] <== lc;
    }

    signal chain[NCHUNK + 1];
    component h[NCHUNK];
    chain[0] <== 0;
    for (var j = 0; j < NCHUNK; j++) {
        h[j] = Poseidon(2);
        h[j].inputs[0] <== chain[j];
        h[j].inputs[1] <== packed[j];
        chain[j + 1] <== h[j].out;
    }

    component bind = Poseidon(4);
    bind.inputs[0] <== chain[NCHUNK];
    bind.inputs[1] <== salt;
    bind.inputs[2] <== roundId;
    bind.inputs[3] <== client;
    commitment <== bind.out;
}

// Draft size for early testing. The full model in the proposal (rank-4 LoRA on
// two layers, ~26k parameters) uses D = 26114; adjust D and the Powers-of-Tau
// file together (see circuits/README.md).
component main {public [normBoundSq, roundId, client]} = NormBound(1024, 15);
