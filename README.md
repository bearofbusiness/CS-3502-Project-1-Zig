# CS-3502-Project-1-Zig
## About
This is my mutli thread and futex implmentation for my Operating systems class written in zig. It will only work on linux x86_64 due to me using direct syscalls and not using zig's built in librarry for futex. There are 3 main files for 3 different binaries. The first is for "Project A: Multi-Threading Implementation" and the second and the third is for "Project B: Inter-Process Communication". </br></br>
There are 2 different mutex structs one that has deadlock detection and one that doesn't. 
## Installation
Install [Zig](https://github.com/ziglang/zig/wiki/Install-Zig-from-a-Package-Manager) and [Git](https://git-scm.com/downloads)</br>
`git clone https://github.com/bearofbusiness/CS-3502-Project-1-Zig.git && cd CS-3502-Project-1-Zig`
## Multi-Threading & Mutex Implementation
### Run
`zig build run -Dmain=main1`
### Output
![output](images/main1.gif)
## IPC
### Run
`zig build -Dmain=main2 && zig build -Dmain=main3 && echo "Testing main2's output\n" && ./zig-out/bin/main2 && sleep 2 && echo "\n\nPiping main2 into main3"  && ./zig-out/bin/main2 | ./zig-out/bin/main3`
### Output
![output](images/main2-3.gif)
