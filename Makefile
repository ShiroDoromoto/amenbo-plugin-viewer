# ルートの Makefile は束ねるだけ。
#
# 部品ごとにツールチェーンが違う（プラグインは Go、Worker は Node、アプリは Flutter）ので、
# ビルドの実体は各部品の Makefile が持ち、ここはそこへ渡す。
#
#   make plugin / worker / app   その部品だけをビルドする
#   make build / test / clean    3部品まとめて
#
# Makefile を持たない部品は飛ばす。骨格の段階では中身の無い部品があるので、全部そろうまで
# `make build` が通らない状態を作らないためである。

PARTS := plugin worker app

.DEFAULT_GOAL := help

# $(1) 部品名 / $(2) その部品の Makefile に渡すターゲット
define delegate
	@if [ -f $(1)/Makefile ]; then \
		echo "==> $(1): $(2)"; \
		$(MAKE) -C $(1) $(2); \
	else \
		echo "==> $(1): Makefile がまだ無いので飛ばす"; \
	fi
endef

help:
	@echo 'make plugin   プラグイン（Go）をビルドする'
	@echo 'make worker   Worker（Cloudflare）をビルドする'
	@echo 'make app      アプリ（Flutter）をビルドする'
	@echo 'make build    3部品すべてをビルドする'
	@echo 'make test     ガード ＋ 3部品すべてのテストを走らせる'
	@echo 'make guards   ツリーの形を見るガードだけを走らせる'
	@echo 'make clean    3部品すべての生成物を消す'

build: $(addprefix build-,$(PARTS))
test: guards $(addprefix test-,$(PARTS))
clean: $(addprefix clean-,$(PARTS))

# 部品に属さない検査。見ているのはツリーの形——どの部品の Makefile にも置けないので、束ねる側が持つ。
# CI の guards ジョブもこれを回す。数秒で終わるので、部品ごとの反復とは別に締めで通ればよい。
guards:
	@set -e; for g in guards/*.sh; do "$$g"; done

$(addprefix build-,$(PARTS)): build-%:
	$(call delegate,$*,build)

$(addprefix test-,$(PARTS)): test-%:
	$(call delegate,$*,test)

$(addprefix clean-,$(PARTS)): clean-%:
	$(call delegate,$*,clean)

# `make plugin` のように部品名だけで呼べる短縮。部品名はディレクトリ名でもあるので、
# .PHONY に入れておかないと「もう在る」と見なされて何も走らない。
$(PARTS): %: build-%

.PHONY: help build test clean guards $(PARTS) \
	$(addprefix build-,$(PARTS)) \
	$(addprefix test-,$(PARTS)) \
	$(addprefix clean-,$(PARTS))
