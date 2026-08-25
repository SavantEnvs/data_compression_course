// Standalone reproducer for the elias_fano m_l==0 division-by-zero. See README.md here.
// Build:  g++ -std=c++11 -include cstdint -mbmi -mbmi2 -msse4.2 -mpopcnt -fsanitize=undefined \
//             -fno-sanitize-recover=all repro.cpp -o repro && ./repro
#include <cstdint>
#include <vector>
#include <iostream>
#include <fstream>

#include "../../../../3_list_compressors/code/elias_fano.hpp"

int main() {
    std::vector<uint32_t> values = {1, 2, 3, 4, 5};  // dense: u == n == 5
    elias_fano ef;
    ef.encode(values.data(), values.size());

    std::vector<uint32_t> out(values.size());
    ef.decode(out.data());  // division by zero inside size() (see README.md)

    std::cout << "no crash (unexpected)" << std::endl;
    return 0;
}
