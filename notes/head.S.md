**idmap_pg_dir**是identity mapping使用的页表。
**swapper_pg_dir**是kernel image mapping初始阶段使用的页表。pgd地址默认初始化为这个值。

**init_idmap_pg_dir**是identity mapping全局页表，会加载到页表寄存器。

**init_pg_dir**高地址全局页表，最终的内核页表，加载到页表寄存器。

请注意，这里的内存是一段连续内存。也就是说页表（PGD/PUD/PMD）都是连在一起的，地址相差PAGE_SIZE（4k）。
identity mapping主要是打开MMU的过度阶段，因此对于identity mapping不需要映射整个kernel，只需要映射操作MMU代码相关的部分。这段代码是利用linux中常用手段自定义代码段，自定义的代码段的名称是".idmap.text"。除此之外，肯定还需要在链接脚本中声明两个标量，用来标记代码段的开始和结束。可以从vmlinux.lds.S中找到答案。

```
    . = ALIGN(SZ_4K);                
    __idmap_text_start = .;                
    *(.idmap.text)                    
    __idmap_text_end = .;
```

**head.S启动过程**

```
primary_entry  
 -->record_mmu_state<从系统控制寄存器提取mmu开启关闭状态放入x19>  
 -->preserve_boot_args<把BootLoader传递的x0-x3寄存器放入boot_args数组>  
 -->create_idmap<创建虚地址到物理地址的一一映射，开启MMU要用到>  
 -->init_kernel_el<初始化CPU boot mode，EL1还是EL2,检查是否支持VHE虚拟化等>  
 -->__cpu_setup<enable FP/SIMD,debug pmu访问权限，mair寄存器内存属性设置，页表和内存调试功能Feature设置，虚地址物理地址bit长度设置>  
 -->__primary_switch  
    -->__enable_mmu<使能mmu>  
    -->__pi_kaslr_early_init<传入FDT地址，从FDT读取seed并生成一个offset>
    -->clear_page_tables<清空旧的页表>
    -->create_kernel_mapping<创建新的内核页表，内核位于高地址空间>
    -->__relocate_kernel<重定位 .rel.dyn段>  
    -->__primary_switched  
       -->init_cpu_task  
       -->设置中断向量表，取__fdt_pointer和内核镜像地址
       -->set_cpu_boot_mode_flag<把CPU boot mode保存到全局变量>
       -->清bss段
       -->kasan_early_init<kasan功能初步初始化，arm64 MTE Feature可硬件支持kasan>
       -->early_fdt_map<尝试remap fdt，可能失败>  
       -->init_feature_override<读取代码中的配置并初始化cpu Feature>  
       -->start_kernel  
```