// Fuzz driver for the uncrustify CLI. uncrustify.cpp's main() is compiled as
// uncrustify_main() (-Dmain=uncrustify_main); this main() feeds it the fuzz input on stdin.
//   uncrustify_format <file>: byte0 -> language, bytes1-2 -> config file from tests/config, rest -> source.
//   uncrustify_config <file>: the whole file is the config; a fixed C++ sample is formatted with it.
// The mode is taken from the binary's name.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

#include "cfg_list.h"

int uncrustify_main(int argc, char **argv);

static const char *const kLangs[] = {
   "C", "CPP", "CPP", "C", "D", "CS", "JAVA", "OC", "OC+", "VALA", "PAWN", "ECMA"
};

static const char kSample[] =
   "#include <vector>\n#define MAX(a,b) ((a)>(b)?(a):(b))\n"
   "namespace ns{\ntemplate<typename T,int N=3>class Foo:public Base<T>,private Other{\n"
   "public:\nFoo(int a,T b):x(a),y(b){}\nvirtual ~Foo()=default;\n"
   "int bar(const std::vector<T>&v,char *s)const noexcept{\n"
   "if(v.empty())return -1;else if(s==nullptr){return 0;}\n"
   "for(auto&e:v){switch(e){case 1:x++;break;default:{y=e;}}}\n"
   "int arr[3]={1,2,3};auto l=[&](int q)->int{return q*2;};\n"
   "while(x<N)x+=l(1); do{--x;}while(x>0);\n"
   "try{throw 1;}catch(...){}\nreturn x?arr[0]:arr[1];}\n"
   "private:int x;T y;};\n}// ns\n"
   "/* block\n comment */ struct S{unsigned a:3;enum E{A,B=2}e;};\n"
   "static int f(int a,\nint b){return a+b;}\n";

static int memfd_with(const unsigned char *p, size_t n)
{
   int fd = memfd_create("fuzz", 0);
   if (fd < 0)
   {
      return -1;
   }
   while (n > 0)
   {
      ssize_t w = write(fd, p, n);
      if (w <= 0)
      {
         close(fd);
         return -1;
      }
      p += w;
      n -= (size_t)w;
   }
   lseek(fd, 0, SEEK_SET);
   return fd;
}

int main(int argc, char **argv)
{
   if (argc < 2)
   {
      fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
      return 2;
   }
   const char *base = strrchr(argv[0], '/');
   base = base ? base + 1 : argv[0];
   const bool config_mode = strstr(base, "config") != nullptr;

   FILE *f = fopen(argv[1], "rb");
   if (f == nullptr)
   {
      return 2;
   }
   std::vector<unsigned char> data;
   unsigned char              buf[65536];
   size_t                     n;
   while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
   {
      data.insert(data.end(), buf, buf + n);
      if (data.size() > (1u << 20))
      {
         break;
      }
   }
   fclose(f);

   std::string cfg_path;
   std::string lang;
   int         in_fd;
   if (config_mode)
   {
      int cfd = memfd_with(data.data(), data.size());
      if (cfd < 0)
      {
         return 2;
      }
      cfg_path = "/proc/self/fd/" + std::to_string(cfd);
      lang     = "CPP";
      in_fd    = memfd_with((const unsigned char *)kSample, sizeof(kSample) - 1);
   }
   else
   {
      unsigned char hdr[3] = { 0, 0, 0 };
      size_t        off    = 0;
      while (off < 3 && off < data.size())
      {
         hdr[off] = data[off];
         off++;
      }
      lang     = kLangs[hdr[0] % (sizeof(kLangs) / sizeof(kLangs[0]))];
      cfg_path = kConfigs[(hdr[1] | (hdr[2] << 8)) % kConfigCount];
      in_fd    = memfd_with(data.data() + off, data.size() - off);
   }
   if (in_fd < 0)
   {
      return 2;
   }
   dup2(in_fd, 0);
   int sink = memfd_create("out", 0);
   if (sink >= 0)
   {
      dup2(sink, 1);
   }

   std::vector<std::string> args = { "uncrustify", "-q", "-c", cfg_path, "-l", lang };
   std::vector<char *>      av;
   for (auto &a : args)
   {
      av.push_back(&a[0]);
   }
   av.push_back(nullptr);
   return uncrustify_main((int)args.size(), av.data());
}
