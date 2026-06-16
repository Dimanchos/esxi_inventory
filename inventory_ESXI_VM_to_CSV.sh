#!/bin/bash
#DEBUG=true

declare -A HOST_CREDS
HOST_CREDS["192.168.1.65"]="Password1"
HOST_CREDS["192.168.1.66"]="Password2"


USER="root"

printf '\xEF\xBB\xBF' > ESXI_VM_report.csv
echo "IP_Хоста_ESXi;Имя_ВМ;VM_ID;Состояние_Питания;Количество_vCPU;ОЗУ_ГБ;Занято_Диска_ГБ;Гостевая_ОС;IP_Адреса_ВМ;Сети_PortGroup;Кол-во_Дисков;Пути_к_Дискам_vmdk;Имя_Datastore;Описание_ВМ;Статус_VMware_Tools" >> ESXI_VM_report.csv

for host in "${!HOST_CREDS[@]}"; do
    pass="${HOST_CREDS[$host]}"
    echo "Опрос: $host"
    
    VM_IDS=$(sshpass -p "$pass" ssh -n -o StrictHostKeyChecking=no $USER@$host "vim-cmd vmsvc/getallvms 2>/dev/null | tail -n +2 | awk '{print \$1}'" | tr -d '\r')
    
    for vmid in $VM_IDS; do
        [[ ! "$vmid" =~ ^[0-9]+$ ]] && continue
        
        SUMMARY=$(sshpass -p "$pass" ssh -n -o StrictHostKeyChecking=no $USER@$host "vim-cmd vmsvc/get.summary $vmid 2>/dev/null" | tr -d '\r')
        CONFIG=$(sshpass -p "$pass" ssh -n -o StrictHostKeyChecking=no $USER@$host "vim-cmd vmsvc/get.config $vmid 2>/dev/null" | tr -d '\r')
        GUEST=$(sshpass -p "$pass" ssh -n -o StrictHostKeyChecking=no $USER@$host "vim-cmd vmsvc/get.guest $vmid 2>/dev/null" | tr -d '\r')
        
        VMX_PATH=$(echo "$CONFIG" | grep 'vmPathName =' | head -1 | tr -d '\r')
        DS_NAME=$(echo "$VMX_PATH" | sed 's/.*vmPathName = "\[\([^]]*\)\].*/\1/')
        VM_DIR=$(echo "$VMX_PATH" | sed 's/.*vmPathName = "\[[^]]*\] \([^/]*\).*/\1/')
        
        VMX_CONTENT=$(sshpass -p "$pass" ssh -n -o StrictHostKeyChecking=no $USER@$host "cat '/vmfs/volumes/$DS_NAME/$VM_DIR/$VM_DIR.vmx' 2>/dev/null" | tr -d '\r')
        
        # === ИЗВЛЕЧЕНИЕ ОПИСАНИЯ ===
        annotation=$(echo "$VMX_CONTENT" | grep -i 'annotation' | head -1 | sed 's/.*annotation[[:space:]]*=[[:space:]]*"\(.*\)"/\1/' | tr -d '\r')
        
        if [ -z "$annotation" ]; then
            annotation=$(echo "$CONFIG" | grep -i 'annotation' | head -1 | sed 's/.*annotation[[:space:]]*=[[:space:]]*"\(.*\)"/\1/' | tr -d '\r')
        fi
        
        annotation_trimmed=$(echo "$annotation" | tr -d '[:space:]')
        
        if [ -z "$annotation_trimmed" ] || [ "$annotation_trimmed" = '""' ]; then
            annotation="Нет описания"
        else
            annotation=$(echo "$annotation" | \
                tr '\r\n' '  ' | \
                sed 's/|0A/ /g; s/\\n/ /g' | \
                tr -s ' ' | \
                sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
                sed 's/,/;/g' | \
                sed 's/"/'\''/g')
            
            annotation_trimmed=$(echo "$annotation" | tr -d '[:space:]')
            if [ -z "$annotation_trimmed" ]; then
                annotation="Нет описания"
            fi
        fi
        
        # ДИСКИ
        disk_list=$(echo "$VMX_CONTENT" | grep -E '(scsi|sata|nvme)[0-9:]+\.fileName =' | grep '\.vmdk"' | sed 's/.*= "\([^"]*\)".*/\1/' | while read disk; do
            if [[ "$disk" == /* ]]; then
                echo "$disk"
            else
                echo "[$DS_NAME] $VM_DIR/$disk"
            fi
        done | tr '\n' ';' | sed 's/;$//')
        
        # СЕТИ
        net_list=$(echo "$VMX_CONTENT" | grep -E 'ethernet[0-9]+\.networkName =' | sed 's/.*= "\([^"]*\)".*/\1/' | sort -u | tr '\n' ';' | sed 's/;$//')
        
        if [ -n "$disk_list" ] && [ "$disk_list" != "" ]; then
            disk_count=$(echo "$disk_list" | tr ';' '\n' | wc -l)
        else
            disk_count=0
            disk_list=""
        fi
        
        # IP
        ip_addr=$(echo "$GUEST" | grep -E 'ipAddress = "[0-9]+\.' | sed 's/.*ipAddress = "\([^"]*\)".*/\1/' | grep -v '\.1$' | grep -v '^$' | sort -u | tr '\n' ';' | sed 's/;$//')
        
        if [ -z "$ip_addr" ]; then
            ip_addr=$(echo "$SUMMARY" | grep 'ipAddress =' | sed 's/.*ipAddress = "\([^"]*\)".*/\1/' | grep -v '<unset>' | tr '\n' ';' | sed 's/;$//')
        fi
        
        # ОСТАЛЬНЫЕ ПОЛЯ
        p_state=$(echo "$SUMMARY" | grep 'powerState =' | head -1 | sed 's/.*powerState = "\([^"]*\)".*/\1/')
        tools_status=$(echo "$SUMMARY" | grep 'toolsStatus =' | head -1 | sed 's/.*toolsStatus = "\([^"]*\)".*/\1/')
        used_bytes=$(echo "$SUMMARY" | grep 'committed =' | head -1 | awk '{print $3}' | tr -d ',')
        
        vmname=$(echo "$CONFIG" | grep 'name =' | head -1 | sed 's/.*name = "\([^"]*\)".*/\1/')
        g_os=$(echo "$CONFIG" | grep 'guestFullName =' | head -1 | sed 's/.*guestFullName = "\([^"]*\)".*/\1/')
        n_cpu=$(echo "$CONFIG" | grep 'numCPU =' | head -1 | awk '{print $3}' | tr -d ',')
        m_mb=$(echo "$CONFIG" | grep 'memoryMB =' | head -1 | awk '{print $3}' | tr -d ',')
        
        m_gb=$(awk "BEGIN {printf \"%.0f\", ${m_mb:-0}/1024}")
        used_gb=$(awk "BEGIN {printf \"%.0f\", ${used_bytes:-0}/(1024^3)}")
        
        [ -z "$vmname" ] && vmname="Unknown"
        [ -z "$p_state" ] && p_state="Unknown"
        [ -z "$g_os" ] && g_os="Unknown"
        [ -z "$tools_status" ] && tools_status="Unknown"
        [ -z "$ip_addr" ] && ip_addr="Нет данных"
        [ -z "$net_list" ] && net_list="Нет данных"
        [ -z "$disk_list" ] && disk_list="Нет данных"
        [ -z "$DS_NAME" ] && DS_NAME="Unknown"
        [ -z "$n_cpu" ] && n_cpu=0
        
        echo "${host};\"${vmname}\";${vmid};${p_state};${n_cpu};${m_gb};${used_gb};\"${g_os}\";\"${ip_addr}\";\"${net_list}\";${disk_count};\"${disk_list}\";\"${DS_NAME}\";\"${annotation}\";${tools_status}" >> ESXI_VM_report.csv
        
    done
    echo "  Готово: $host"
done

echo "================================"
echo "Готово! Файл: ESXI_VM_REPORTS.csv"
