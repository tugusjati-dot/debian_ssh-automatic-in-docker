#!/bin/bash
# Setup
# cd debian_ssh-automatic-in-docker
# chmod +x setup.sh
# to run use ./setup.sh

# --- Konfigurasi ---
DOCKER_DIR="$HOME/docker-ssh"
DOCKERFILE_PATH="$DOCKER_DIR/Dockerfile"
IMAGE_NAME="debian-ssh:bookworm"
CONTAINER_NAME="debian_ssh"
HOST_SSH_PORT="2222" # Port exposed on the host machine
USER_NAME="user1"
USER_PASS="1234" # !! PERINGATAN: GANTI INI DENGAN PASSWORD AMAN ANDA !!
NGROK_TOKEN="TOKEN_KAMU" # !! PERINGATAN: GANTI INI DENGAN TOKEN NGROK ASLI ANDA !!
# ---------------------

echo "--- SSH/Ngrok Docker Automation Script ---"


if ! command -v docker &> /dev/null; then
    echo "❌ ERROR: Docker tidak ditemukan. Harap instal Docker terlebih dahulu."
    exit 1
fi


mkdir -p "$DOCKER_DIR"
cd "$DOCKER_DIR" || exit


BUILD_NEW_IMAGE=false
if ! docker images -q "$IMAGE_NAME" | grep -q .; then
    echo "Image Docker tidak ditemukan. Akan membuat Dockerfile dan Image baru..."
    BUILD_NEW_IMAGE=true
else
    
    if docker ps -a --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        echo "Kontainer lama '$CONTAINER_NAME' ditemukan. Menghentikan dan menghapus..."
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
    fi
    echo "Image Docker '$IMAGE_NAME' ditemukan. Melewati proses build, tetapi kontainer akan dibuat baru."
fi


if [ "$BUILD_NEW_IMAGE" = true ]; then
    cat <<EOF > "$DOCKERFILE_PATH"
# Dockerfile: Debian 12 + openssh-server + single root user (user1)
FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive

# install openssh and necessary tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-server ca-certificates wget tar sudo ufw && \
    rm -rf /var/lib/apt/lists/*

# create runtime dir for sshd
RUN mkdir -p /var/run/sshd

# create non-root user (user1) and set password
ARG USER=$USER_NAME
ARG PASS=$USER_PASS
RUN useradd -m -s /bin/bash "\$USER" && \
    echo "\$USER:\$PASS" | chpasswd && \
    usermod -aG sudo "\$USER"

# Configure sshd: Disable root login, enable password auth
RUN sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

# generate host keys
RUN ssh-keygen -A

EXPOSE 22

# Setup indicator file for initial setup state
RUN touch /etc/.initial_setup_needed

# run sshd in foreground
CMD ["/usr/sbin/sshd","-D"]
EOF

   
    echo "Membangun image '$IMAGE_NAME'..."
    docker build -t "$IMAGE_NAME" .
    if [ $? -ne 0 ]; then
        echo "❌ Gagal membangun image Docker."
        exit 1
    fi
    
    
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
fi


echo "Membuat dan menjalankan kontainer baru..."
docker run -d --name "$CONTAINER_NAME" -p "$HOST_SSH_PORT":22 "$IMAGE_NAME"
if [ $? -ne 0 ]; then
    echo "❌ Gagal menjalankan kontainer. Pastikan port $HOST_SSH_PORT tidak digunakan."
    exit 1
fi



SETUP_MARKER_CMD="test -f /etc/.setup_complete"

n
if docker exec "$CONTAINER_NAME" $SETUP_MARKER_CMD; then
    echo "✅ Setup Ngrok/SSH/UFW di dalam kontainer sudah selesai. Melewati instalasi."
else
    echo "Melakukan setup Ngrok/SSH/UFW di dalam kontainer..."


    docker exec -u root "$CONTAINER_NAME" /bin/bash -c "
        echo 'Mengeksekusi setup awal di dalam kontainer...'

        # 1. Download dan install Ngrok
        cd /tmp
        wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz -O ngrok.tgz
        tar -xvzf ngrok.tgz
        mv ngrok /usr/local/bin/
        
        # 2. Konfigurasi Ngrok Auth Token sebagai user1 (Fix Ngrok 4018)
        # Menjalankan perintah ini sebagai user1 memastikan token disimpan di /home/user1/.config/ngrok/ngrok.yml
        su - "$USER_NAME" -c \"/usr/local/bin/ngrok config add-authtoken $NGROK_TOKEN\"
        
        # 3. UFW setup (Diabaikan jika gagal, karena Docker sudah mengurus networking)
        # Output error UFW disembunyikan karena wajar terjadi di lingkungan Docker minimal
        echo 'Mengkonfigurasi UFW (Output error diabaikan)...'
        ufw --force enable 2>/dev/null || true
        ufw allow 22 2>/dev/null || true
        ufw allow $HOST_SSH_PORT/tcp 2>/dev/null || true

        # 4. Buat penanda setup selesai
        touch /etc/.setup_complete
        echo 'Setup awal selesai.'
    "
    if [ $? -ne 0 ]; then
        echo "❌ Gagal menjalankan setup awal di dalam kontainer. Harap periksa log kontainer (docker logs $CONTAINER_NAME)."
        exit 1
    fi
fi


echo "--------------------------------------------------------"
echo "Kontainer '$CONTAINER_NAME' sudah siap. SSH dapat diakses di port $HOST_SSH_PORT pada host Anda (ssh $USER_NAME@localhost -p $HOST_SSH_PORT)."

NGROK_PORT=""
while true; do
    read -rp "➡️ Masukkan PORT DALAM KONTAINER (biasanya 22) yang ingin di-tunnel menggunakan Ngrok: " NGROK_PORT
    if [[ "$NGROK_PORT" =~ ^[0-9]+$ ]] && [ "$NGROK_PORT" -ge 1 ] && [ "$NGROK_PORT" -le 65535 ]; then
        break
    else
        echo "Port tidak valid. Harap masukkan angka port antara 1 dan 65535."
    fi
done

echo "Memulai Ngrok Tunnel TCP di port $NGROK_PORT..."
echo "Catatan: Ngrok akan berjalan interaktif, dan Anda akan melihat alamat tunnel di layar, seperti menjalankan manual."
echo "Untuk menghentikan Ngrok, tekan Ctrl+C."
echo ""


docker exec -it -u "$USER_NAME" "$CONTAINER_NAME" /usr/local/bin/ngrok tcp "$NGROK_PORT"

echo "Ngrok tunnel dihentikan."


echo "--------------------------------------------------------"
echo "Kontainer Docker '$CONTAINER_NAME' masih berjalan di latar belakang."
echo "Untuk menghentikan: docker stop $CONTAINER_NAME"
echo "Untuk menjalankan kembali Ngrok, jalankan lagi script ini: bash $0"
echo "--------------------------------------------------------"
