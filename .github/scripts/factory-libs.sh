# shellcheck shell=bash
# 工場のデザイン担当が入れてよい道具（npm のパッケージ）。factory-add-lib.sh と factory.sh が読む（source する）。
# 決まった名前だけを、決まった版の幅で入れる（知らない名前は入れない）。
#   lib_pkgs <名前>  … 入れるパッケージを1行1つで出す。知らない名前なら何も出さずに 1 で終わる
# shellcheck disable=SC2034  # 読む側（factory-add-lib.sh・factory.sh）が使う
FACTORY_LIB_NAMES="gsap @gsap/react lenis motion three @react-three/fiber @react-three/drei"
lib_pkgs() {
  case "$1" in
    gsap | @gsap/react) printf '%s\n' "gsap@^3" "@gsap/react@^2" ;;
    lenis) printf '%s\n' "lenis@^1" ;;
    motion) printf '%s\n' "motion@^12" ;;
    three) printf '%s\n' "three@^0" "@types/three@^0" ;;
    @react-three/fiber) printf '%s\n' "three@^0" "@types/three@^0" "@react-three/fiber@^9" ;;
    @react-three/drei) printf '%s\n' "three@^0" "@types/three@^0" "@react-three/fiber@^9" "@react-three/drei@^10" ;;
    *) return 1 ;;
  esac
}
