#include <cstdio>
extern "C" const char* ecru_google_ink_configuration();
int main(int argc, char** argv) {
  FILE* output = argc == 2 ? std::fopen(argv[1], "wb") : stdout;
  if (!output) return 1;
  if (std::fprintf(output, "%s\n", ecru_google_ink_configuration()) < 0) return 1;
  return output == stdout ? std::fflush(output) : std::fclose(output);
}
