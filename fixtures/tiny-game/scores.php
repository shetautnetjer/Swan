<?php
function top_scores(array $scores, int $n): array
{
    rsort($scores);
    return array_slice($scores, 0, $n);
}

$scores = [10, 40, 25];
echo implode(", ", top_scores($scores, 2));
echo "\n";
