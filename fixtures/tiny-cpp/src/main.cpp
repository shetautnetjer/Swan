#include "score.h"

int main() {
    int score = 0;
    score = add_points(score, 10);
    return score == 10 ? 0 : 1;
}
