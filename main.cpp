#include <iostream>
#include <string.h>

// 声明我们将要从其他文件调用的函数
int run_server();
int run_client();

int main(int argc, char* argv[]) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " [s | c]" << std::endl;
        std::cerr << "  s: start as server" << std::endl;
        std::cerr << "  c: start as client" << std::endl;
        return 1;
    }

    if (strcmp(argv[1], "s") == 0) {
        return run_server();
    }
    else if (strcmp(argv[1], "c") == 0) {
        return run_client();
    }
    else {
        std::cerr << "Invalid argument. Use 's' for server or 'c' for client." << std::endl;
        return 1;
    }
}