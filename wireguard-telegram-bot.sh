#!/bin/bash

# Telegram Bot Configuration
TELEGRAM_BOT_TOKEN=""
TELEGRAM_ADMIN_IDS=""  # Comma-separated list of admin Telegram user IDs

# Function to send message via Telegram
send_telegram_message() {
    local chat_id="$1"
    local message="$2"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d "chat_id=$chat_id" \
        -d "text=$message" \
        -d "parse_mode=HTML"
}

# Function to send file via Telegram
send_telegram_file() {
    local chat_id="$1"
    local file_path="$2"
    local caption="$3"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
        -F "chat_id=$chat_id" \
        -F "document=@$file_path" \
        -F "caption=$caption"
}

# Function to send QR code image via Telegram
send_telegram_qr() {
    local chat_id="$1"
    local config_file="$2"
    local temp_qr="/tmp/wg-qr-$RANDOM.png"
    qrencode -t PNG -o "$temp_qr" < "$config_file"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendPhoto" \
        -F "chat_id=$chat_id" \
        -F "photo=@$temp_qr" \
        -F "caption=WireGuard Configuration QR Code"
    rm -f "$temp_qr"
}

# Function to check if user is admin
is_admin() {
    local user_id="$1"
    echo "$TELEGRAM_ADMIN_IDS" | tr ',' '\n' | grep -q "^${user_id}$"
    return $?
}

# Function to list all clients
list_clients() {
    grep '^# BEGIN_PEER' /etc/wireguard/wg0.conf | cut -d ' ' -f 3
}

# Function to handle Telegram bot commands
handle_command() {
    local chat_id="$1"
    local user_id="$2"
    local command="$3"
    local args="$4"

    if ! is_admin "$user_id"; then
        send_telegram_message "$chat_id" "⛔️ Unauthorized. This incident will be reported."
        return 1
    fi

    case "$command" in
        "/start")
            local help_text="Welcome to WireGuard Manager Bot!\n\n"
            help_text+="Available commands:\n"
            help_text+="/addclient <name> - Add new WireGuard client\n"
            help_text+="/removeclient <name> - Remove existing client\n"
            help_text+="/listclients - List all clients\n"
            help_text+="/getconfig <name> - Get client configuration"
            send_telegram_message "$chat_id" "$help_text"
            ;;
            
        "/addclient")
            if [ -z "$args" ]; then
                send_telegram_message "$chat_id" "⚠️ Usage: /addclient <client_name>"
                return 1
            fi
            
            local client=$(echo "$args" | sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' | cut -c-15)
            
            if grep -q "^# BEGIN_PEER $client$" /etc/wireguard/wg0.conf; then
                send_telegram_message "$chat_id" "⚠️ Client '$client' already exists!"
                return 1
            fi
            
            # Use existing functions to create client
            dns="9.9.9.9, 149.112.112.112"  # Default to Quad9
            new_client_setup
            wg addconf wg0 <(sed -n "/^# BEGIN_PEER $client/,/^# END_PEER $client/p" /etc/wireguard/wg0.conf)
            
            # Send configuration file and QR code
            send_telegram_file "$chat_id" ~/"$client.conf" "Configuration file for $client"
            send_telegram_qr "$chat_id" ~/"$client.conf"
            send_telegram_message "$chat_id" "✅ Client '$client' added successfully!"
            ;;
            
        "/removeclient")
            if [ -z "$args" ]; then
                send_telegram_message "$chat_id" "⚠️ Usage: /removeclient <client_name>"
                return 1
            fi
            
            local client="$args"
            if ! grep -q "^# BEGIN_PEER $client$" /etc/wireguard/wg0.conf; then
                send_telegram_message "$chat_id" "⚠️ Client '$client' does not exist!"
                return 1
            fi
            
            # Remove client using existing functionality
            wg set wg0 peer "$(sed -n "/^# BEGIN_PEER $client$/,\$p" /etc/wireguard/wg0.conf | grep -m 1 PublicKey | cut -d " " -f 3)" remove
            sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/d" /etc/wireguard/wg0.conf
            rm -f ~/"$client.conf"
            
            send_telegram_message "$chat_id" "✅ Client '$client' removed successfully!"
            ;;
            
        "/listclients")
            local clients=$(list_clients)
            if [ -z "$clients" ]; then
                send_telegram_message "$chat_id" "No clients found."
            else
                local message="📑 WireGuard Clients:\n\n"
                while read -r client; do
                    message+="• $client\n"
                done <<< "$clients"
                send_telegram_message "$chat_id" "$message"
            fi
            ;;
            
        "/getconfig")
            if [ -z "$args" ]; then
                send_telegram_message "$chat_id" "⚠️ Usage: /getconfig <client_name>"
                return 1
            fi
            
            local client="$args"
            if [ ! -f ~/"$client.conf" ]; then
                send_telegram_message "$chat_id" "⚠️ Configuration for client '$client' not found!"
                return 1
            fi
            
            send_telegram_file "$chat_id" ~/"$client.conf" "Configuration file for $client"
            send_telegram_qr "$chat_id" ~/"$client.conf"
            ;;
            
        *)
            send_telegram_message "$chat_id" "⚠️ Unknown command. Use /start for help."
            ;;
    esac
}

# Function to run Telegram bot
run_telegram_bot() {
    local last_update_id=0
    
    while true; do
        # Get updates from Telegram
        local updates=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?offset=$((last_update_id + 1))")
        
        # Process each update
        while read -r update_id chat_id user_id message; do
            if [ -n "$update_id" ]; then
                last_update_id=$update_id
                if [ -n "$message" ]; then
                    local command=$(echo "$message" | cut -d' ' -f1)
                    local args=$(echo "$message" | cut -s -d' ' -f2-)
                    handle_command "$chat_id" "$user_id" "$command" "$args"
                fi
            fi
        done < <(echo "$updates" | jq -r '.result[] | "\(.update_id) \(.message.chat.id) \(.message.from.id) \(.message.text)"')
        
        sleep 1
    done
}

# Add this to the main script's installation section
setup_telegram_bot() {
    echo
    echo "Telegram Bot Setup"
    echo "-----------------"
    read -p "Enter Telegram Bot Token: " bot_token
    read -p "Enter Admin Telegram User IDs (comma-separated): " admin_ids
    
    # Save configuration
    cat << EOF > /etc/wireguard/telegram-bot.conf
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_ADMIN_IDS="$admin_ids"
EOF
    chmod 600 /etc/wireguard/telegram-bot.conf
    
    # Create systemd service
    cat << 'EOF' > /etc/systemd/system/wireguard-telegram-bot.service
[Unit]
Description=WireGuard Telegram Bot
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wireguard-telegram-bot
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Create the bot script
    cat << 'EOF' > /usr/local/bin/wireguard-telegram-bot
#!/bin/bash
source /etc/wireguard/telegram-bot.conf
$(declare -f send_telegram_message send_telegram_file send_telegram_qr is_admin list_clients handle_command run_telegram_bot)
run_telegram_bot
EOF
    chmod +x /usr/local/bin/wireguard-telegram-bot
    
    # Install required packages
    if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
        apt-get update
        apt-get install -y jq curl
    elif [[ "$os" == "centos" || "$os" == "fedora" ]]; then
        dnf install -y jq curl
    fi
    
    # Start the bot
    systemctl enable --now wireguard-telegram-bot.service
    
    echo
    echo "Telegram bot has been set up and started!"
    echo "Use /start in your Telegram bot to see available commands."
}
