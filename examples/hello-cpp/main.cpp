#include <iostream>
#include <string>
#include <vector>

int main() {
    const std::vector<std::string> tools = {"gcc", "g++", "gdb"};
    std::cout << "MinGW toolchain is ready:" << std::endl;
    for (const std::string& tool : tools) {
        std::cout << "  - " << tool << std::endl;
    }
    return 0;
}
