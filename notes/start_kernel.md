由head.S跳转到start_kernel函数开始执行内核初始化流程：

```
start_kernel
    -->set_task_stack_end_magic<在init_task栈顶设置一个magic，用于检测溢出>
    -->smp_setup_processor_id<读取并保存core 0的cpuid>
        -->read_cpuid_mpidr<从mpidr寄存器读取cpuid>
        -->set_cpu_logical_map<设置__cpu_logical_map[0]=mpidr>
    -->debug_objects_early_init<初始化obj_hash,obj_static_pool,调试用到>
        -->raw_spin_lock_init<初始化obj_hash表每个bucket spinlock>
        -->hlist_add_head<obj_static_pool[i].node加入到obj_pool>
    -->init_vmlinux_build_id<从.note segment查找build id>
    -->cgroup_init_early<cgroups基本初始化>
        -->init_cgroup_root<初始化cgroup树root>
        -->cgroup_init_subsys<初始化subsystem>
    -->local_irq_disable<关中断>
    -->boot_cpu_init<把boot CPU添加到online,present,active,possible map>
    -->page_address_init<high memory, 64位cpu为空>
    -->early_security_init<初期安全模块初始化>
    -->setup_arch<体系结构相关初始化>
        -->setup_initial_init_mm<初始化init 内存管理器>
        -->early_fixmap_init<初始化L0, L1, L2 fixmap区域对应的页表entry>
```


