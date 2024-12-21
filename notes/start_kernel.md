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
    -->kaslr_init<Kernel Address Space Layout Random 内核地址随机化初始化>
        -->early_fixmap_init<初始化L0, L1, L2 fixmap区域对应的页表entry>
            -->early_fixmap_init_pud<初始化Page Upper Directory>
                -->__p4d_populate<启用5级页表则初始化p4d，p4d在pgd和pud之间>
                    -->set_p4d<pgtable_l4_enabled = true即启用5级页表，才会执行>
                -->pud_offset_kimg<获取pud地址>
                    -->p4d_to_folded_pud<pgtable_l4_enabled = false, 获取addr在p4d中的entry地址>
                -->early_fixmap_init_pmd<初始化pud entry的值和pmd>
                    -->__pud_populate<填充pud entry>
                        -->set_pud<设置pud entry>
                            -->set_swapper_pgd<非5级页表填充pgd entry>
                            --><5级页表直接填entry>
                    -->early_fixmap_init_pte<初始化pte的上级页表>
                        -->__pmd_populate<>
                            -->set_pmd<填充pmd entry>
        -->early_ioremap_init<初始化 7 个虚地址slot，每个 slot 指向一段 fixmap区域>
            -->early_ioremap_setup<循环初始化slot>
        -->setup_machine_fdt<映射fdt地址>
            -->fixmap_remap_fdt<映射到pte>
                -->create_mapping_noalloc<映射第一个chunk，以便读取header信息>
                    -->__create_pgd_mapping
                        -->__create_pgd_mapping_locked
                            -->alloc_init_p4d
                                -->alloc_init_pud
                                    -->alloc_init_cont_pmd
                                        -->init_pmd
                                            -->alloc_init_cont_pte
                                                -->init_pte
                                                    -->__set_pte_nosync<填充pte>
                -->从fdt header获取size
                -->create_mapping_noalloc<映射剩余data>
            -->memblock_reserve<reserve fdt物理地址>
                -->memblock_add_range<添加fdt range, 添加的内存如果存在重叠，需要处理合并>
                    -->memblock_insert_region
            -->fixmap_remap_fdt<映射完成后页表设置read only, 防止fdt被修改>
            -->of_flat_dt_get_machine_name<从 fdt查找machine信息>
            -->dump_stack_set_arch_desc<设置machine信息到dump stack desc>

```
