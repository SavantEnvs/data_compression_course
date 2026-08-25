// Standalone reproducer for the write_gamma(UINT32_MAX) abort. See README.md in this directory.
// Build:  g++ -std=c++11 -include cstdint repro.cpp -o repro && ./repro
#include <cstdint>
#include <iostream>
#include <fstream>

#include "../../../../2_integer_codes/code/integer_codes.hpp"

int main() {
    bit_vector_builder builder;
    write_gamma(builder, 0xFFFFFFFFu);  // aborts: msb(0) assert (see README.md)
    std::cout << "no crash (unexpected)" << std::endl;
    return 0;
}
