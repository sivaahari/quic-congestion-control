#!/usr/bin/env bash
# Figures -> deck -> geometry check -> render. One command, so the rendered
# images can never be of a stale deck.
set -uo pipefail
cd /home/sivaa/pvseed || exit 1

python3 analysis/make_survey_figures.py || exit 1
echo
python3 analysis/make_deck_phase2.py || exit 1
echo
python3 _qa/deck_geometry_qa.py paper/PhaseII_Review.pptx | tail -6
echo
bash _qa/render_deck.sh >/tmp/render.log 2>&1
tail -2 /tmp/render.log
