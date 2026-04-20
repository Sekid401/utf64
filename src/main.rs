use utf64::{encode, decode, payload_byte_size};

fn main() {
    let cases: &[(&str, &str)] = &[
        ("hello",             "lowercase hello"),
        ("Hello",             "capitalized Hello"),
        ("",                  "empty string"),
        ("the rain in spain", "tier0-heavy sentence"),
        ("Hello, World!",     "mixed ascii"),
        ("Héllo",             "accented char (Tier2)"),
        ("日本語",             "Japanese (Tier2)"),
    ];

    println!("UTF-64 Rust Test Suite");
    println!("{}", "=".repeat(40));
    for (input, desc) in cases {
        let enc  = encode(input);
        let dec  = decode(&enc);
        let hex  = enc.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
        let pass = &dec == input;
        println!("[{}] {}", if pass { "PASS" } else { "FAIL" }, desc);
        if !pass {
            println!("  expected: {:?}", input);
            println!("  got:      {:?}", dec);
        } else {
            println!("  {:?} → {} payload bytes", input, payload_byte_size(input));
        }
        println!("  hex: {}\n", hex);
    }
}
