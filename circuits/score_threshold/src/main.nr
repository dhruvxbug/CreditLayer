use std::hash::poseidon2::Poseidon2;

fn main(
    score: u64,
    salt: Field,
    borrower: pub Field,
    threshold: pub u64,
    commitment: pub Field
) {
    // Verify commitment: Poseidon2([score, salt, borrower]) == commitment.
    // Including the borrower public input prevents wallet A's proof from being
    // replayed by wallet B.
    let computed_commitment = Poseidon2::hash([score as Field, salt, borrower], 3);
    assert(computed_commitment == commitment, "Invalid commitment");

    // Prove score >= threshold without revealing score
    assert(score >= threshold, "Score below threshold");
}

#[test]
fn test_valid_score_above_threshold() {
    let score: u64 = 700;
    let salt: Field = 12345;
    let borrower: Field = 0x1234;
    let threshold: u64 = 600;
    let commitment = Poseidon2::hash([score as Field, salt, borrower], 3);
    main(score, salt, borrower, threshold, commitment);
}

#[test(should_fail)]
fn test_score_below_threshold_fails() {
    let score: u64 = 500;
    let salt: Field = 12345;
    let borrower: Field = 0x1234;
    let threshold: u64 = 600;
    let commitment = Poseidon2::hash([score as Field, salt, borrower], 3);
    main(score, salt, borrower, threshold, commitment);
}
